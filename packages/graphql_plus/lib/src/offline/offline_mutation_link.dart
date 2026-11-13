import 'dart:async';

import 'package:gql/ast.dart' show OperationType;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

import 'package:graphql_plus/src/offline/connectivity.dart';
import 'package:graphql_plus/src/offline/mutation_queue.dart';
import 'package:meta/meta.dart';

/// A queued mutation that reached the server.
@immutable
class DeliveredMutation {
  const DeliveredMutation({required this.mutation, required this.response});

  /// The entry that was replayed.
  final QueuedMutation mutation;

  /// The last response the server gave for it.
  ///
  /// A response carrying GraphQL errors is a delivery too: the server answered,
  /// so the queue is done with the entry and the caller can act on the errors.
  final Response response;
}

/// A replay that could not be delivered.
@immutable
class OfflineMutationFailure {
  const OfflineMutationFailure({
    required this.mutation,
    required this.error,
    this.stackTrace,
  });

  /// The entry that is still queued.
  final QueuedMutation mutation;

  /// The transport-level failure.
  final Object error;

  final StackTrace? stackTrace;
}

/// Resolved instead of a response when a mutation is queued rather than sent.
///
/// The mutation is stored in the queue under [mutationId] and will be replayed
/// when connectivity returns; [OfflineMutationLink.onDelivered] reports the
/// response it gets.
class OfflineMutationException extends LinkException {
  OfflineMutationException({
    required this.mutationId,
    required this.queueLength,
  }) : super(null, null);

  /// The queue id of the stored mutation.
  final String mutationId;

  /// How many mutations are waiting after this one was queued.
  final int queueLength;

  @override
  String toString() =>
      'OfflineMutationException($mutationId, $queueLength queued)';
}

/// A [Link] that queues mutations made while offline and replays them, in
/// order, when connectivity returns.
///
/// Queries and subscriptions are passed straight through, as is every mutation
/// made while online. Only a mutation made while [connectivity] reports offline
/// takes the queue: the caller's request resolves with an
/// [OfflineMutationException] and the entry is sent when the monitor reports
/// online again.
///
/// A replay goes through the link handed to the constructor, never through the
/// chain that called this one, so a replay can not re-enter the queue.
///
/// The queue is drained one entry at a time, oldest first, so a server sees the
/// writes in the order the user made them. A transport failure stops the drain
/// and leaves that entry at the head, so a later attempt retries it before any
/// newer write.
///
/// {@tool snippet}
/// ```dart
/// final queue = OfflineMutationQueue(store: hiveStore);
/// final link = OfflineMutationLink(
///   forward: HttpLink(uri: uri),
///   connectivity: connectivityMonitor,
///   queue: queue,
/// );
/// link.onDelivered.listen((delivery) => print(delivery.response.data));
/// final client = GraphQLClient(link: link, cache: cache);
/// ```
/// {@end-tool}
class OfflineMutationLink extends Link {
  OfflineMutationLink({
    required Link forward,
    required ConnectivityMonitor connectivity,
    OfflineMutationQueue? queue,
  })  : _forward = forward,
        _connectivity = connectivity,
        queue = queue ?? OfflineMutationQueue(),
        _delivered = StreamController<DeliveredMutation>.broadcast(),
        _failures = StreamController<OfflineMutationFailure>.broadcast() {
    _connectivitySubscription =
        connectivity.onConnectivityChanged.listen(_onConnectivityChanged);
  }

  final Link _forward;
  final ConnectivityMonitor _connectivity;
  final StreamController<DeliveredMutation> _delivered;
  final StreamController<OfflineMutationFailure> _failures;
  StreamSubscription<bool>? _connectivitySubscription;
  Future<int>? _inFlightFlush;

  /// The queue this link drains.
  final OfflineMutationQueue queue;

  /// Emits every mutation that was replayed and answered by the server.
  ///
  /// A response carrying GraphQL errors is emitted here too.
  Stream<DeliveredMutation> get onDelivered => _delivered.stream;

  /// Emits every replay that could not be delivered.
  ///
  /// The mutation stays queued; the next flush retries it.
  Stream<OfflineMutationFailure> get onReplayFailure => _failures.stream;

  /// Whether the client is online right now.
  bool get isOnline => _connectivity.isOnline;

  /// Whether [request] is a mutation.
  static bool isMutation(Request request) =>
      request.operation.getOperationType() == OperationType.mutation;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) {
    final NextLink next = forward ?? _forward.request;
    if (!isMutation(request) || _connectivity.isOnline) {
      return next(request);
    }
    return _enqueue(request);
  }

  /// Drain the queue now, whether or not connectivity changed.
  ///
  /// A flush that is already running is joined rather than started twice, so
  /// two callers cannot reorder the queue between them.
  Future<int> flush() {
    final Future<int>? inFlight = _inFlightFlush;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<int> flush = _flush();
    _inFlightFlush = flush;
    unawaited(flush.whenComplete(() {
      if (identical(_inFlightFlush, flush)) {
        _inFlightFlush = null;
      }
    }));
    return flush;
  }

  @override
  Future<void> dispose() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    if (!_delivered.isClosed) {
      await _delivered.close();
    }
    if (!_failures.isClosed) {
      await _failures.close();
    }
  }

  Stream<Response> _enqueue(Request request) async* {
    final String mutationId;
    try {
      mutationId = await queue.enqueue(request);
    } catch (error, stackTrace) {
      yield* Stream<Response>.error(error, stackTrace);
      return;
    }
    yield* Stream<Response>.error(
      OfflineMutationException(
        mutationId: mutationId,
        queueLength: queue.length,
      ),
      StackTrace.current,
    );
  }

  Future<int> _flush() async {
    if (queue.isEmpty) {
      return 0;
    }
    return queue.flush(_send);
  }

  Future<void> _send(QueuedMutation mutation) async {
    try {
      final List<Response> responses =
          await _forward.request(mutation.asRequest).toList();
      if (responses.isEmpty) {
        throw StateError(
          'The link produced no response for ${mutation.id}',
        );
      }
      if (!_delivered.isClosed) {
        _delivered.add(
          DeliveredMutation(mutation: mutation, response: responses.last),
        );
      }
    } catch (error, stackTrace) {
      if (!_failures.isClosed) {
        _failures.add(
          OfflineMutationFailure(
            mutation: mutation,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
      rethrow;
    }
  }

  void _onConnectivityChanged(bool online) {
    if (online) {
      unawaited(flush());
    }
  }
}
