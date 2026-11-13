import 'dart:async';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:rxdart/rxdart.dart';

import './websocket_client.dart';

export './websocket_client.dart';
export './websocket_messages.dart';

/// A Universal Websocket [Link] implementation to support the websocket transport.
/// It supports subscriptions, query and mutation operations as well.
///
/// NOTE: the actual socket connection will only get established after a [Request] is handled by this [WebSocketLink].
/// If you'd like to connect to the socket server instantly, call the [connectOrReconnect] method after creating this [WebSocketLink] instance.
class WebSocketLink extends Link {
  /// Creates a new [WebSocketLink] instance with the specified config.
  WebSocketLink(
    this.url, {
    this.config = const SocketClientConfig(),
    this.subProtocol = GraphQLProtocol.graphqlWs,
  });

  final String url;
  final String subProtocol;
  final SocketClientConfig config;

  // cannot be final because we're changing the instance upon a header change.
  SocketClient? _socketClient;

  /// Set synchronously by [dispose], before its first `await`.
  ///
  /// [dispose] hands the socket teardown to the event loop, and [connectOrReconnect] is
  /// public API, so a caller can interleave the two. Without this flag the rebuild installs a
  /// client that [dispose] then nulls without closing — a live socket nobody owns.
  bool _isDisposed = false;

  /// Stable connection state for this link, surviving [connectOrReconnect].
  ///
  /// [SocketClient] is disposed and rebuilt on every reconnect, so subscribing to
  /// `getSocketClient.connectionState` binds a caller to an instance that is about to
  /// be thrown away. This subject is owned by the link and keeps forwarding across
  /// rebuilds, so a listener that needs to know the subscription dropped can rely on it.
  final BehaviorSubject<SocketConnectionState> _connectionState =
      BehaviorSubject<SocketConnectionState>.seeded(
    SocketConnectionState.notConnected,
  );

  StreamSubscription<SocketConnectionState>? _connectionStateSubscription;

  /// The current connection state of the underlying socket.
  ///
  /// Emits [SocketConnectionState.notConnected] before the first connection, then every
  /// transition — including `connecting` / `connected` after a reconnect — on the same
  /// stream. Callers do not need a [SocketClient] reference to observe a lost connection.
  Stream<SocketConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<Response> request(Request request, [forward]) async* {
    if (_socketClient == null) {
      connectOrReconnect();
    }

    yield* _socketClient!.subscribe(request, true);
  }

  /// Connects or reconnects to the server with the specified headers.
  ///
  /// Throws a [StateError] if this link has been disposed — a disposed link has no
  /// [connectionState] subject left to forward into, so rebuilding here would surface as an
  /// uncaught async `Bad state` from inside the socket's stream delivery instead of at the call
  /// site. Create a new [WebSocketLink] instead.
  void connectOrReconnect() {
    if (_isDisposed) {
      throw StateError('WebSocketLink is disposed; create a new link');
    }
    _socketClient?.dispose();
    _connectionStateSubscription?.cancel();
    _socketClient = SocketClient(
      url,
      config: config,
      protocol: subProtocol,
    );
    _connectionStateSubscription = _socketClient!.connectionState
        // The socket client's stream is a BehaviorSubject, so a listener attached after
        // construction gets the current value replayed to it. This link already seeds its own
        // subject with notConnected, so forwarding that replay would emit notConnected twice
        // per connect; drop the replay and forward every transition after it.
        .skip(1)
        .listen((state) {
      if (!_connectionState.isClosed) {
        _connectionState.add(state);
      }
    });
  }

  SocketClient? get getSocketClient => _socketClient;

  /// Disposes the underlying socket client explicitly. Only use this, if you want to disconnect from
  /// the current server in favour of another one. If that's the case, create a new [WebSocketLink] instance.
  Future<void> dispose() async {
    _isDisposed = true;
    // Capture and clear before awaiting: a [connectOrReconnect] landing in this window must
    // find no client to replace and no forwarder to cancel, or dispose would null a freshly
    // installed client without ever closing it.
    final client = _socketClient;
    final forwarding = _connectionStateSubscription;
    _socketClient = null;
    _connectionStateSubscription = null;
    await client?.dispose();
    await forwarding?.cancel();
    if (!_connectionState.isClosed) {
      await _connectionState.close();
    }
  }
}
