import 'dart:async';
import 'dart:convert';

import 'package:gql/ast.dart' show DocumentNode;
import 'package:gql/language.dart' show parseString, printNode;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart' show LinkException;
import 'package:meta/meta.dart';

/// Carries the [QueuedMutation.idempotencyKey] of a replayed mutation.
///
/// A replayed request carries this entry so a link further down the chain (or a
/// server that understands an idempotency header) can tell the replay of a
/// queued write from a brand new one.
@immutable
class OfflineIdempotencyKey extends ContextEntry {
  const OfflineIdempotencyKey(this.key);

  /// The key of the queued mutation being executed.
  final String key;

  @override
  List<Object?> get fieldsForEquality => <Object?>[key];
}

/// A mutation that was accepted while the client was offline and is waiting to
/// be sent.
///
/// The payload is stored as GraphQL source rather than as a [DocumentNode] so
/// the entry can be written to a [MutationQueueStore] and read back in a later
/// process.
@immutable
class QueuedMutation {
  QueuedMutation({
    required this.id,
    required this.document,
    required this.idempotencyKey,
    required this.createdAt,
    this.operationName,
    this.variables = const <String, dynamic>{},
    this.attempts = 0,
    this.lastError,
  });

  /// Build an entry from a JSON map produced by [toJson].
  factory QueuedMutation.fromJson(Map<String, dynamic> json) {
    final String? id = json['id'] as String?;
    final String? document = json['document'] as String?;
    final String? idempotencyKey = json['idempotencyKey'] as String?;
    if (id == null || document == null || idempotencyKey == null) {
      throw FormatException(
        'A queued mutation needs id, document and idempotencyKey',
        json,
      );
    }
    final Object? rawVariables = json['variables'];
    final Object? rawCreatedAt = json['createdAt'];
    final Object? rawAttempts = json['attempts'];
    return QueuedMutation(
      id: id,
      document: document,
      idempotencyKey: idempotencyKey,
      createdAt: rawCreatedAt is String
          ? DateTime.tryParse(rawCreatedAt) ??
              DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(0),
      operationName: json['operationName'] as String?,
      variables: rawVariables is Map
          ? Map<String, dynamic>.from(rawVariables)
          : const <String, dynamic>{},
      attempts: rawAttempts is int ? rawAttempts : 0,
      lastError: json['lastError'] as String?,
    );
  }

  /// Queue-unique id, stable across store round trips.
  final String id;

  /// The mutation's GraphQL source, as printed from its document.
  final String document;

  /// The operation name, when the document holds more than one operation.
  final String? operationName;

  /// The variables the mutation was called with.
  final Map<String, dynamic> variables;

  /// Identifies this payload on the wire, so a replay of a queued write can be
  /// told apart from a brand new one. Deduplication compares payloads, not
  /// keys; see [OfflineMutationQueue.enqueue].
  final String idempotencyKey;

  /// When the mutation was queued.
  final DateTime createdAt;

  /// How many times a replay of this entry has failed.
  final int attempts;

  /// Why the last replay attempt failed, if it did.
  final String? lastError;

  /// The parsed [document].
  ///
  /// Parsed on first use, so a queue restored from a store does not pay for the
  /// entries it never replays.
  late final DocumentNode documentNode = parseString(document);

  /// The entry as a request, carrying its [OfflineIdempotencyKey].
  ///
  /// The context of the original request is not preserved: a [Context] is not
  /// serializable, so only the [OfflineIdempotencyKey] is rebuilt here. Callers
  /// who attach entries to `MutationOptions.context` (auth tokens handled by
  /// links, tracing data, …) must arrange for those entries to exist again at
  /// replay time — they will not come back from the queue on their own.
  Request get asRequest => Request(
        operation: Operation(
          document: documentNode,
          operationName: operationName,
        ),
        variables: variables,
        context: Context().withEntry<OfflineIdempotencyKey>(
          OfflineIdempotencyKey(idempotencyKey),
        ),
      );

  /// A copy of this entry with the replay bookkeeping replaced.
  QueuedMutation copyWith({
    int? attempts,
    String? lastError,
  }) =>
      QueuedMutation(
        id: id,
        document: document,
        idempotencyKey: idempotencyKey,
        createdAt: createdAt,
        operationName: operationName,
        variables: variables,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
      );

  /// The JSON form persisted by a [MutationQueueStore].
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'document': document,
        'operationName': operationName,
        'variables': variables,
        'idempotencyKey': idempotencyKey,
        'createdAt': createdAt.toIso8601String(),
        'attempts': attempts,
        'lastError': lastError,
      };

  @override
  String toString() => 'QueuedMutation($id, $operationName, $variables)';
}

/// Persistence for the pending mutations.
///
/// Implement this on top of whatever durable storage the host has (Hive, a
/// database, a file) and hand it to [OfflineMutationQueue]. A store is read
/// once, when the queue is built, and written on every change.
///
/// [read] is synchronous by design, so a durable store cannot load lazily
/// inside it: open the Hive box, the database or the file, and finish loading
/// its contents, *before* constructing the [OfflineMutationQueue].
abstract class MutationQueueStore {
  /// Every entry currently held by the store, oldest first.
  ///
  /// Must return synchronously; a host backed by async storage loads
  /// everything it needs before the queue that consumes this method exists.
  List<Map<String, dynamic>> read();

  /// Replace the contents of the store with [entries].
  void write(List<Map<String, dynamic>> entries);
}

/// A [MutationQueueStore] that lives in memory, and is lost with the process.
///
/// This is the default: it is enough for a session, and a host that needs the
/// queue to survive a restart supplies a durable store.
class InMemoryMutationQueueStore implements MutationQueueStore {
  InMemoryMutationQueueStore([List<Map<String, dynamic>>? entries])
      : _entries = <Map<String, dynamic>>[
          for (final Map<String, dynamic> entry
              in entries ?? const <Map<String, dynamic>>[])
            _deepCopy(entry),
        ];

  final List<Map<String, dynamic>> _entries;

  @override
  List<Map<String, dynamic>> read() => <Map<String, dynamic>>[
        for (final Map<String, dynamic> entry in _entries) _deepCopy(entry),
      ];

  @override
  void write(List<Map<String, dynamic>> entries) {
    _entries
      ..clear()
      ..addAll(entries.map(_deepCopy));
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> entry) =>
      jsonDecode(jsonEncode(entry)) as Map<String, dynamic>;
}

/// Thrown when the queue will not accept another entry.
class MutationQueueFullException extends LinkException {
  MutationQueueFullException(this.message) : super(null, null);

  final String message;

  @override
  String toString() => 'MutationQueueFullException($message)';
}

/// A FIFO queue of mutations made while the client was offline.
///
/// The queue owns the ordering, the deduplication and the bookkeeping (attempt
/// count and last error); sending is the caller's job, which keeps the queue
/// testable and lets [OfflineMutationLink] own the transport.
class OfflineMutationQueue {
  OfflineMutationQueue({
    MutationQueueStore? store,
    this.maxEntries = defaultMaxEntries,
    this.deduplicate = true,
  })  : _store = store ?? InMemoryMutationQueueStore(),
        _entries = <QueuedMutation>[] {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be at least 1');
    }
    for (final Map<String, dynamic> json in _store.read()) {
      final QueuedMutation entry = QueuedMutation.fromJson(json);
      _entries.add(entry);
      _ids.add(entry.id);
    }
  }

  /// How many entries a queue holds unless told otherwise.
  static const int defaultMaxEntries = 100;

  final MutationQueueStore _store;
  final List<QueuedMutation> _entries;
  final Set<String> _ids = <String>{};
  Future<int>? _inFlightFlush;
  int _nextId = 1;

  /// The most entries the queue will hold.
  final int maxEntries;

  /// Whether an identical payload already in the queue is stored again.
  final bool deduplicate;

  /// The pending entries, oldest first.
  List<QueuedMutation> get pending =>
      List<QueuedMutation>.unmodifiable(_entries);

  /// How many mutations are waiting.
  int get length => _entries.length;

  /// Whether nothing is waiting.
  bool get isEmpty => _entries.isEmpty;

  /// Whether the queue is at [maxEntries].
  bool get isFull => _entries.length >= maxEntries;

  /// The mutation that will be sent next, if any.
  QueuedMutation? get head => _entries.isEmpty ? null : _entries.first;

  /// Append [request] to the queue and return the id of the stored entry.
  ///
  /// When [deduplicate] is on and an entry with the same payload is already
  /// pending, that entry is kept and its id is returned. Entries are compared
  /// by their canonical payload (printed document, operation name and
  /// canonicalized variables) and not by the hashed [QueuedMutation
  /// .idempotencyKey]: the hash is only as wide as the platform keeps its
  /// integers — dart2js truncates it to 32 bits — so a collision there would
  /// silently fold a distinct write into an existing entry.
  ///
  /// Throws a [MutationQueueFullException] when the queue is at [maxEntries]
  /// and the payload is not already queued.
  Future<String> enqueue(
    Request request, {
    String? idempotencyKey,
    DateTime? now,
  }) async {
    final String document = printNode(request.operation.document);
    final String? operationName = request.operation.operationName;
    final String key = idempotencyKey ??
        offlineIdempotencyKeyFor(
          document: document,
          operationName: operationName,
          variables: request.variables,
        );

    final QueuedMutation? queued =
        _byPayload(document, operationName, request.variables);
    if (queued != null) {
      return deduplicate ? queued.id : _append(request, key, now);
    }
    return _append(request, key, now);
  }

  String _append(Request request, String key, DateTime? now) {
    if (isFull) {
      throw MutationQueueFullException(
        'The queue is full ($length of $maxEntries)',
      );
    }
    final QueuedMutation entry = QueuedMutation(
      id: _allocateId(),
      document: printNode(request.operation.document),
      operationName: request.operation.operationName,
      variables: Map<String, dynamic>.from(request.variables),
      idempotencyKey: key,
      createdAt: now ?? DateTime.now().toUtc(),
    );
    _entries.add(entry);
    _persist();
    return entry.id;
  }

  /// Whether an entry with [id] is pending.
  bool contains(String id) => _ids.contains(id);

  /// Whether an entry with [idempotencyKey] is pending.
  bool containsIdempotencyKey(String idempotencyKey) =>
      _byKey(idempotencyKey) != null;

  /// The pending entry with [id], if any.
  QueuedMutation? byId(String id) {
    for (final QueuedMutation entry in _entries) {
      if (entry.id == id) {
        return entry;
      }
    }
    return null;
  }

  /// Drop the entry with [id], returning whether it was pending.
  Future<bool> remove(String id) async {
    final QueuedMutation? entry = byId(id);
    if (entry == null) {
      return false;
    }
    _entries.remove(entry);
    _ids.remove(entry.id);
    _persist();
    return true;
  }

  /// Send the queued mutations with [send], oldest first.
  ///
  /// [send] completes normally when the mutation was delivered (the server
  /// answered) and throws when it was not. Each delivered entry is removed
  /// before the next one is sent; a throw stops the flush and leaves that entry
  /// at the head with [QueuedMutation.attempts] incremented.
  ///
  /// The entry being sent may be removed (by [remove] or [clear], or by a
  /// listener on the caller's own bookkeeping) while the send is in flight;
  /// such an entry is simply gone, and the flush continues with whatever the
  /// queue holds after the await instead of dropping or crashing on it.
  ///
  /// A flush that is already running is joined rather than started twice, so
  /// two concurrent callers cannot interleave two drain loops on one list.
  /// Returns how many mutations were delivered.
  Future<int> flush(Future<void> Function(QueuedMutation mutation) send) {
    final Future<int>? inFlight = _inFlightFlush;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<int> flush = _flush(send);
    _inFlightFlush = flush;
    unawaited(flush.whenComplete(() {
      if (identical(_inFlightFlush, flush)) {
        _inFlightFlush = null;
      }
    }));
    return flush;
  }

  Future<int> _flush(
      Future<void> Function(QueuedMutation mutation) send) async {
    var delivered = 0;
    while (_entries.isNotEmpty) {
      final QueuedMutation entry = _entries.first;
      try {
        await send(entry);
      } catch (error) {
        _recordFailure(entry, error);
        break;
      }
      // The entry may have been removed (or the queue cleared) while the
      // send was in flight; only drop it if it is still the head we sent.
      if (_entries.isNotEmpty && identical(_entries.first, entry)) {
        _entries.removeAt(0);
        _ids.remove(entry.id);
        delivered++;
        _persist();
      }
    }
    return delivered;
  }

  /// Drop every pending entry.
  Future<void> clear() async {
    _entries.clear();
    _ids.clear();
    _persist();
  }

  QueuedMutation? _byKey(String idempotencyKey) {
    for (final QueuedMutation entry in _entries) {
      if (entry.idempotencyKey == idempotencyKey) {
        return entry;
      }
    }
    return null;
  }

  /// The pending entry whose payload matches [document], [operationName] and
  /// [variables] exactly, if any.
  QueuedMutation? _byPayload(
    String document,
    String? operationName,
    Map<String, dynamic> variables,
  ) {
    final String canonical = _canonicalVariablesJson(variables);
    for (final QueuedMutation entry in _entries) {
      if (entry.document == document &&
          entry.operationName == operationName &&
          _canonicalVariablesJson(entry.variables) == canonical) {
        return entry;
      }
    }
    return null;
  }

  void _recordFailure(QueuedMutation entry, Object error) {
    final int index = _entries.indexOf(entry);
    if (index < 0) {
      return;
    }
    final QueuedMutation updated = entry.copyWith(
      attempts: entry.attempts + 1,
      lastError: '$error',
    );
    _entries[index] = updated;
    _persist();
  }

  String _allocateId() {
    String id;
    do {
      id = 'mutation-${_nextId++}';
    } while (!_ids.add(id));
    return id;
  }

  void _persist() => _store.write(<Map<String, dynamic>>[
        for (final QueuedMutation entry in _entries) entry.toJson(),
      ]);
}

/// Derive the idempotency key of a mutation payload.
///
/// The key is deterministic (the same payload yields the same key across runs)
/// and independent of variable ordering, so a mutation replayed after a restart
/// is still recognized as the one that was queued. It is a wire-facing tag, not
/// a dedup token: [OfflineMutationQueue] deduplicates by comparing canonical
/// payloads, because this hash is only as wide as the platform keeps its
/// integers (dart2js truncates it to 32 bits, native keeps 64).
String offlineIdempotencyKeyFor({
  required String document,
  String? operationName,
  Map<String, dynamic> variables = const <String, dynamic>{},
}) {
  final String payload = jsonEncode(<Object?>[
    document,
    operationName,
    _canonicalize(variables),
  ]);
  return _fnv1a(payload);
}

/// The JSON form of the canonicalized [variables], for payload comparison.
String _canonicalVariablesJson(Map<String, dynamic> variables) =>
    jsonEncode(_canonicalize(variables));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final String key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is Iterable) {
    return value.map(_canonicalize).toList();
  }
  return value;
}

/// FNV-1a over the canonical payload. Deterministic across runs on one
/// platform, which a persisted idempotency key has to be.
///
/// This is 64-bit FNV-1a on the VM. On web (dart2js) bitwise arithmetic
/// truncates to 32 bits and the multiply loses precision past 2^53, so the
/// key there is effectively ~32-bit and does not match what native computes.
/// Nothing depends on that width: the queue never deduplicates on this value
/// (entries are compared by their canonical payload), it only rides the
/// replayed request as [OfflineIdempotencyKey].
String _fnv1a(String input) {
  var hash = 0xcbf29ce484222325;
  for (final int byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
