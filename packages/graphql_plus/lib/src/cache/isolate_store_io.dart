import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:meta/meta.dart';

import 'package:graphql_plus/src/cache/hive_store.dart';
import 'package:graphql_plus/src/cache/store.dart';

/// A [Store] whose encode and durable persistence run on a background isolate.
///
/// Normalizing a response and writing it out is CPU work: [HiveStore] encodes
/// every entry and flushes it to disk on the caller's isolate, which is the
/// jank this store exists to remove. [IsolateStore] keeps a hot in-memory
/// mirror for reads — the synchronous [Store] contract leaves no room for an
/// async read — and hands every mutation to a worker isolate, which applies it
/// to a real [Store] (a [HiveStore] box, by default) off the UI thread.
///
/// ```dart
/// final store = await IsolateStore.hive(boxName: 'graphqlClientStore');
/// final client = GraphQLClient(
///   link: HttpLink(uri: 'https://example.com/graphql'),
///   cache: GraphQLCache(store: store),
/// );
/// ```
///
/// The public client and cache API is unchanged: this is an ordinary [Store],
/// so it drops into [GraphQLCache] wherever a [HiveStore] would.
///
/// **Cost.** The mirror is the price of the synchronous contract: the whole
/// normalized graph is held on the UI isolate as well as on the worker. What
/// moves off-isolate is the encode plus the write, which is where the jank
/// came from. A caller that needs the mirror to be authoritative must not
/// mutate the worker's box behind this store's back.
///
/// **Ordering.** Sends on a [SendPort] are FIFO, so the worker applies
/// mutations in the order they were made. [flush] is the await point that
/// proves it: it completes once every mutation sent so far has been applied.
@immutable
class IsolateStore extends Store {
  IsolateStore._(this._session)
      : _data = HashMap<String, Map<String, dynamic>?>();

  final _IsolateSession _session;

  /// Hot mirror backing every synchronous read.
  final Map<String, Map<String, dynamic>?> _data;

  /// Spawns an [IsolateStore] whose worker holds an [InMemoryStore].
  ///
  /// Nothing is persisted, so this is the backend for tests and benchmarks: it
  /// exercises the isolate plumbing without touching the filesystem.
  static Future<IsolateStore> memory() => _open(const _BackendSpec.memory());

  /// Spawns an [IsolateStore] whose worker holds a [HiveStore] box named
  /// [boxName], durably written under [path] when one is given.
  ///
  /// The box is owned by the worker: it is opened there and closed by [close].
  /// Do not open the same box name on the calling isolate.
  static Future<IsolateStore> hive({
    required String boxName,
    String? path,
  }) =>
      _open(_BackendSpec.hive(boxName, path));

  static Future<IsolateStore> _open(_BackendSpec spec) async {
    final store = IsolateStore._(await _IsolateSession.start(spec));
    await store._hydrate();
    return store;
  }

  Future<void> _hydrate() async {
    final snapshot = await _session.send({'op': 'snapshot'});
    _data
      ..clear()
      ..addAll(_entitiesFrom(snapshot as Map<Object?, Object?>));
  }

  @override
  Map<String, dynamic>? get(String dataId) {
    _ensureOpen();
    return _data[dataId];
  }

  @override
  void put(String dataId, Map<String, dynamic>? value) {
    _ensureOpen();
    _data[dataId] = value;
    _post({'op': 'put', 'key': dataId, 'value': value});
  }

  @override
  void putAll(Map<String, Map<String, dynamic>?> data) {
    _ensureOpen();
    _data.addAll(data);
    _post({'op': 'putAll', 'entries': data});
  }

  @override
  void delete(String dataId) {
    _ensureOpen();
    _data.remove(dataId);
    _post({'op': 'delete', 'key': dataId});
  }

  @override
  void reset() {
    _ensureOpen();
    _data.clear();
    _post({'op': 'reset'});
  }

  @override
  Map<String, Map<String, dynamic>?> toMap() {
    _ensureOpen();
    return Map<String, Map<String, dynamic>?>.unmodifiable(_data);
  }

  /// Completes once every mutation sent so far has been applied on the worker,
  /// so everything this store has written is durable.
  Future<void> flush() => _flushAfter(_session.flush());

  /// Flushes, shuts the worker down and closes its box. Idempotent.
  Future<void> close() async {
    if (_session.isClosed) return;
    await _flushAfter(_session.close());
  }

  void _ensureOpen() {
    if (_session.isClosed) {
      throw StateError('IsolateStore is closed');
    }
  }

  /// Sends a mutation without waiting for its acknowledgement.
  ///
  /// A failure on a mutation nobody awaited is recorded and raised by the next
  /// [flush] or [close], rather than surfacing as an unhandled async error.
  void _post(Map<String, Object?> message) {
    _session.send(message).catchError((Object error, StackTrace stack) {
      _session.recordFailure(error);
      return null;
    });
  }

  Future<void> _flushAfter(Future<Object?> flushed) async {
    await flushed;
    _session.raiseFailure();
  }
}

/// Rebuilds the string-keyed entity map a snapshot arrives as.
Map<String, Map<String, dynamic>?> _entitiesFrom(Map<Object?, Object?> raw) {
  final entities = <String, Map<String, dynamic>?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) continue;
    final value = entry.value;
    entities[key] = value is Map
        ? value.map<String, dynamic>((k, v) => MapEntry('$k', v))
        : null;
  }
  return entities;
}

/// One worker isolate plus the request bookkeeping the main isolate keeps for
/// it. Every message is a plain map, so it is sendable as-is.
class _IsolateSession {
  _IsolateSession._(this._replies, this._exits);

  final ReceivePort _replies;
  final ReceivePort _exits;
  final Map<int, Completer<Object?>> _pending = {};

  /// The worker's command port, known once it has reported ready.
  late SendPort _commands;

  int _seq = 0;
  bool _closed = false;
  Object? _failure;

  bool get isClosed => _closed;

  /// How long a worker gets to build its backing store and answer.
  static const bootstrapTimeout = Duration(seconds: 60);

  static Future<_IsolateSession> start(_BackendSpec spec) async {
    final replies = ReceivePort();
    final exits = ReceivePort();
    final bootstrap = Completer<_Bootstrap>();
    late final _IsolateSession session;

    void failAllPending(Object error) {
      for (final completer in session._pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(_IsolateStoreException(error, null));
        }
      }
      session._pending.clear();
    }

    replies.listen((message) {
      if (message is _Bootstrap) {
        if (!bootstrap.isCompleted) bootstrap.complete(message);
        return;
      }
      final reply = message as _Reply;
      final completer = session._pending.remove(reply.id);
      if (completer == null || completer.isCompleted) return;
      final error = reply.error;
      if (error != null) {
        completer.completeError(_IsolateStoreException(error, reply.stack));
      } else {
        completer.complete(reply.value);
      }
    });

    // A worker that dies must release whoever is waiting on it: a leaked
    // completer is a hung caller, not an error.
    exits.listen((_) {
      session._closed = true;
      failAllPending('the isolate store worker exited unexpectedly');
    });

    session = _IsolateSession._(replies, exits);

    try {
      final isolate = await Isolate.spawn<_IsolateBoot>(
        _isolateEntry,
        _IsolateBoot(replies.sendPort, spec),
      );
      isolate.addOnExitListener(exits.sendPort);
      final boot = await bootstrap.future.timeout(bootstrapTimeout);
      final workerPort = boot.workerPort;
      if (workerPort == null) {
        throw StateError(
          'the isolate store worker failed to start: ${boot.error}',
        );
      }
      session._commands = workerPort;
      return session;
    } on Object {
      replies.close();
      exits.close();
      rethrow;
    }
  }

  Future<Object?> send(Map<String, Object?> message) {
    if (_closed) throw StateError('IsolateStore is closed');
    final id = ++_seq;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send({'id': id, ...message});
    return completer.future;
  }

  /// Resolves once the worker has applied every mutation sent before this call.
  Future<Object?> flush() => send({'op': 'flush'});

  Future<Object?> close() async {
    if (_closed) return null;
    try {
      return await send({'op': 'shutdown'});
    } finally {
      _closed = true;
      _replies.close();
      _exits.close();
      _pending.clear();
    }
  }

  /// Records the first failure reported by a mutation nobody awaited.
  void recordFailure(Object error) {
    _failure ??= error;
  }

  /// Raises, and clears, a failure recorded by [IsolateStore._post].
  void raiseFailure() {
    final failure = _failure;
    if (failure == null) return;
    _failure = null;
    throw failure is _IsolateStoreException
        ? failure
        : _IsolateStoreException(failure, null);
  }
}

/// A failure raised on the worker side, carrying the worker's stack when it
/// had one.
class _IsolateStoreException implements Exception {
  const _IsolateStoreException(this.cause, this.workerStack);

  final Object cause;
  final String? workerStack;

  @override
  String toString() => 'IsolateStoreException: $cause'
      '${workerStack == null ? '' : '\n$workerStack'}';
}

/// The sendable description of the backing store the worker should build.
@immutable
class _BackendSpec {
  const _BackendSpec.memory()
      : kind = _kindMemory,
        boxName = null,
        path = null;

  const _BackendSpec.hive(this.boxName, this.path) : kind = _kindHive;

  static const _kindMemory = 'memory';
  static const _kindHive = 'hive';

  final String kind;
  final String? boxName;
  final String? path;
}

/// The worker's first message: its command port, or why it never got one.
@immutable
class _Bootstrap {
  const _Bootstrap.ok(this.workerPort) : error = null;

  const _Bootstrap.failed(this.error) : workerPort = null;

  final SendPort? workerPort;
  final String? error;
}

/// A worker's answer to one request.
@immutable
class _Reply {
  const _Reply(this.id, {this.value, this.error, this.stack});

  final int id;
  final Object? value;
  final String? error;
  final String? stack;
}

/// Payload handed to [_isolateEntry].
@immutable
class _IsolateBoot {
  const _IsolateBoot(this.reply, this.spec);

  final SendPort reply;
  final _BackendSpec spec;
}

/// Builds the backing store and serves mutations until it is told to stop.
Future<void> _isolateEntry(_IsolateBoot boot) async {
  final commands = ReceivePort();

  final Store store;
  final Future<void> Function() dispose;
  try {
    final built = await _buildStore(boot.spec);
    store = built.store;
    dispose = built.dispose;
  } on Object catch (error, stack) {
    boot.reply.send(_Bootstrap.failed('$error\n$stack'));
    commands.close();
    return;
  }

  boot.reply.send(_Bootstrap.ok(commands.sendPort));

  try {
    await for (final message in commands) {
      final request = message as Map<Object?, Object?>;
      final id = request['id'] as int;
      try {
        final value = await _apply(store, request);
        boot.reply.send(_Reply(id, value: value));
      } on Object catch (error, stack) {
        boot.reply.send(_Reply(id, error: '$error', stack: '$stack'));
      }
      if (request['op'] == 'shutdown') break;
    }
  } finally {
    await dispose();
    commands.close();
  }
}

Future<Object?> _apply(Store store, Map<Object?, Object?> request) async {
  switch (request['op']) {
    case 'put':
      store.put(
        request['key'] as String,
        _asEntities(request['value']),
      );
      return null;
    case 'putAll':
      store.putAll(
        (request['entries'] as Map<Object?, Object?>)
            .map<String, Map<String, dynamic>?>((key, value) {
          return MapEntry('$key', _asEntities(value));
        }),
      );
      return null;
    case 'delete':
      store.delete(request['key'] as String);
      return null;
    case 'reset':
      // [Store.reset] is declared `void`, but [HiveStore] overrides it as
      // `Future<void>` so the box clear can be awaited. Route through `dynamic`
      // so both shapes are honoured without changing the public contract.
      final pending = (store as dynamic).reset();
      if (pending is Future) await pending;
      return null;
    case 'snapshot':
      return store.toMap();
    case 'flush':
    case 'shutdown':
      return null;
    default:
      throw UnsupportedError(
        'unknown isolate store operation: ${request['op']}',
      );
  }
}

Map<String, dynamic>? _asEntities(Object? value) {
  if (value is! Map<Object?, Object?>) return null;
  return value.map<String, dynamic>((k, v) => MapEntry('$k', v));
}

Future<({Store store, Future<void> Function() dispose})> _buildStore(
  _BackendSpec spec,
) async {
  switch (spec.kind) {
    case _BackendSpec._kindMemory:
      return (store: InMemoryStore(), dispose: () async {});
    case _BackendSpec._kindHive:
      final hive =
          await HiveStore.open(boxName: spec.boxName!, path: spec.path);
      return (store: hive, dispose: hive.box.close);
    default:
      throw UnsupportedError('unknown isolate store backend: ${spec.kind}');
  }
}
