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
  void connectOrReconnect() {
    _socketClient?.dispose();
    _connectionStateSubscription?.cancel();
    _socketClient = SocketClient(
      url,
      config: config,
      protocol: subProtocol,
    );
    _connectionStateSubscription =
        _socketClient!.connectionState.listen(_connectionState.add);
  }

  SocketClient? get getSocketClient => _socketClient;

  /// Disposes the underlying socket client explicitly. Only use this, if you want to disconnect from
  /// the current server in favour of another one. If that's the case, create a new [WebSocketLink] instance.
  Future<void> dispose() async {
    await _socketClient?.dispose();
    _socketClient = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    if (!_connectionState.isClosed) {
      await _connectionState.close();
    }
  }
}
