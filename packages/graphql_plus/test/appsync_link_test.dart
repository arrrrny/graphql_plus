import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:graphql_plus/graphql_plus.dart';
import 'package:test/test.dart';

/// Polls [condition] every 5 ms until it returns true or [timeout] elapses,
/// failing with a descriptive message instead of spinning until the test
/// framework's timeout.
Future<void> waitForCondition(
  bool Function() condition, {
  required String message,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('$message within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Decodes the AppSync connection query-string parameters of an upgrade
/// request into the raw header JSON object and payload JSON object.
Map<String, dynamic> decodedConnectionAuth(Uri requestUri) {
  final headerParam = requestUri.queryParameters['header'];
  final payloadParam = requestUri.queryParameters['payload'];
  return {
    'header': headerParam == null
        ? null
        : jsonDecode(utf8.decode(base64.decode(headerParam))),
    'payload': payloadParam == null
        ? null
        : jsonDecode(utf8.decode(base64.decode(payloadParam))),
  };
}

/// A mock of the AppSync REALTIME gateway contract:
///
/// - connection auth arrives in the `header`/`payload` query parameters
/// - the upgrade must offer the `graphql-ws` subprotocol
/// - `connection_init` must be answered with `connection_ack`
/// - `start` messages carry `payload.data` (a JSON string) and
///   `payload.extensions.authorization`
/// - `start_ack` confirms the subscription, `data` pushes events,
///   `stop` is answered with `complete`
class MockAppSyncServer {
  late HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];

  /// Upgrade requests, in connection order.
  final List<Uri> connectionRequests = <Uri>[];

  /// Subprotocol values offered on each upgrade request.
  final List<List<String>> offeredProtocols = <List<String>>[];

  /// Every message received from clients, in arrival order.
  final List<Map<String, dynamic>> clientMessages = <Map<String, dynamic>>[];

  /// When set, an upgrade whose `header` carries this authorization value is
  /// answered with `connection_error` and a closed socket (handshake failure).
  String? rejectAuthorizationValue;

  int get connectionCount => connectionRequests.length;

  int countClientMessagesOfType(String type) =>
      clientMessages.where((m) => m['type'] == type).length;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen((request) async {
      connectionRequests.add(request.uri);
      offeredProtocols.add(
          (request.headers.value('sec-websocket-protocol') ?? '')
              .split(',')
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList());
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      final auth = decodedConnectionAuth(request.uri);
      final header = auth['header'] as Map<String, dynamic>?;
      final rejected = rejectAuthorizationValue != null &&
          header != null &&
          header['Authorization'] == rejectAuthorizationValue;
      socket.listen((data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        clientMessages.add(message);
        if (!rejected) {
          _handleMessage(message, socket);
        }
      });
      if (rejected) {
        socket.add(jsonEncode({
          'type': 'connection_error',
          'payload': {
            'errors': [
              {'errorType': 'UnauthorizedException'}
            ]
          },
        }));
        await socket.close();
      }
    });
  }

  void _handleMessage(Map<String, dynamic> message, WebSocket socket) {
    switch (message['type']) {
      case 'connection_init':
        socket.add(jsonEncode({
          'type': 'connection_ack',
          'payload': {'connectionTimeoutMs': 300000},
        }));
        break;
      case 'start':
        socket.add(jsonEncode({'type': 'start_ack', 'id': message['id']}));
        socket.add(jsonEncode({
          'type': 'data',
          'id': message['id'],
          'payload': {
            'data': {'mocked': true},
          },
        }));
        break;
      case 'stop':
        socket.add(jsonEncode({'type': 'complete', 'id': message['id']}));
        break;
    }
  }

  /// Kills every live client socket, as a network loss would.
  void forceCloseSockets() {
    for (final socket in List.of(_sockets)) {
      socket.close();
    }
    _sockets.clear();
  }

  String get url => 'http://127.0.0.1:${_server.port}/graphql';

  Future<void> stop() => _server.close(force: true);
}

/// A JWT provider that hands out a fresh token per call, as a Cognito
/// session would after a refresh.
AppSyncJwtAuth countingJwtProvider(List<String> issued) =>
    AppSyncJwtAuth(() async {
      final token = 'token-${issued.length + 1}';
      issued.add(token);
      return token;
    });

/// A JWT provider whose *connection* authorization succeeds but whose
/// per-message authorization throws for the first [remainingFailures]
/// registrations — a Cognito refresh dying in the window between the
/// websocket upgrade and the start message.
///
/// A provider that fails `authorization()` outright never reaches the
/// per-message path: the connection handshake fails first and the failure
/// is onConnectionLost's domain. This one isolates the serialization
/// failure the socket client must surface on the response stream.
class FlakyOperationJwtAuth extends AppSyncJwtAuth {
  FlakyOperationJwtAuth(this.remainingFailures) : super(() => 'token-ok');

  int remainingFailures;

  @override
  FutureOr<Map<String, String>> authorizationForOperation(
    String serializedOperation,
  ) {
    if (remainingFailures > 0) {
      remainingFailures--;
      throw StateError('refresh failed');
    }
    return super.authorizationForOperation(serializedOperation);
  }
}

Request subscriptionRequest() => Request(
      operation: Operation(
        document: gql('subscription MockSub { mocked }'),
        operationName: 'MockSub',
      ),
    );

void main() {
  group('appSyncRealtimeEndpoint', () {
    test('maps a standard AppSync domain to the realtime domain', () {
      expect(
        appSyncRealtimeEndpoint(
          'https://abc1234567890abcdefghij12.appsync-api.us-east-1.amazonaws.com/graphql',
        ),
        'wss://abc1234567890abcdefghij12.appsync-realtime-api.us-east-1.amazonaws.com/graphql',
      );
    });

    test('appends /realtime to a custom domain', () {
      expect(
        appSyncRealtimeEndpoint('https://api.example.com/graphql'),
        'wss://api.example.com/graphql/realtime',
      );
    });

    test(
        'appends /realtime to a custom domain that merely contains '
        'appsync-api', () {
      // Dot-anchoring: the substring heuristic would rewrite this host to
      // the non-existent myappsync-realtime-api.corp.example.com.
      expect(
        appSyncRealtimeEndpoint(
          'https://myappsync-api.corp.example.com/graphql',
        ),
        'wss://myappsync-api.corp.example.com/graphql/realtime',
      );
    });

    test('maps plain http to ws for local testing', () {
      expect(
        appSyncRealtimeEndpoint('http://127.0.0.1:8899/graphql'),
        'ws://127.0.0.1:8899/graphql/realtime',
      );
    });
  });

  group('AppSync auth providers', () {
    test('API key yields the x-api-key field', () async {
      expect(
        await AppSyncApiKeyAuth('da2-key').authorization(),
        {'x-api-key': 'da2-key'},
      );
    });

    test('JWT provider fetches a fresh token per call', () async {
      var calls = 0;
      final auth = AppSyncJwtAuth(() async => 'jwt-${++calls}');
      expect((await auth.authorization())['Authorization'], 'jwt-1');
      expect((await auth.authorization())['Authorization'], 'jwt-2');
    });

    test('IAM provider passes the signed fields through', () async {
      final auth = AppSyncIamAuth((_) async => const {
            'Authorization': 'AWS4-HMAC-SHA256 ...',
            'x-amz-date': '20260101T000000Z',
          });
      expect(
        await auth.authorization(),
        {
          'Authorization': 'AWS4-HMAC-SHA256 ...',
          'x-amz-date': '20260101T000000Z',
        },
      );
    });

    test('IAM provider signs the serialized operation per message', () async {
      String? signedData;
      final auth = AppSyncIamAuth((serializedOperation) async {
        signedData = serializedOperation;
        return const {'Authorization': 'AWS4-HMAC-SHA256 ...'};
      });
      final data = jsonEncode({
        'operationName': null,
        'variables': <String, dynamic>{},
        'query': 'subscription A { a }',
      });
      expect(
        await auth.authorizationForOperation(data),
        {'Authorization': 'AWS4-HMAC-SHA256 ...'},
      );
      expect(signedData, data);
    });

    test('JWT provider reuses connection auth for operations by default',
        () async {
      final auth = countingJwtProvider(<String>[]);
      await auth.authorization();
      expect(
        await auth
            .authorizationForOperation('{"query":"subscription A { a }"}'),
        {'Authorization': 'token-2'},
      );
    });
  });

  group('AppSyncRequestSerializer', () {
    test('wraps the operation in data and per-message authorization', () async {
      final serializer = AppSyncRequestSerializer(
        AppSyncApiKeyAuth('da2-key'),
        host: 'example.appsync-api.us-east-1.amazonaws.com',
      );
      final request = Request(
        operation: Operation(document: gql('subscription A { a }')),
        variables: {'x': 1},
      );
      final payload = await serializer.serializeRequest(request);

      final data =
          jsonDecode(payload['data'] as String) as Map<String, dynamic>;
      // printNode normalizes the document, so match on content, not layout.
      expect(data['query'], contains('subscription A'));
      expect(data['query'], contains('a'));
      expect(data['variables'], {'x': 1});

      final authorization =
          payload['extensions']['authorization'] as Map<String, dynamic>;
      expect(
          authorization['host'], 'example.appsync-api.us-east-1.amazonaws.com');
      expect(authorization['x-api-key'], 'da2-key');
    });
  });

  group('AppSyncWebSocketLink (mock AppSync realtime server)', () {
    late MockAppSyncServer server;

    setUp(() async {
      server = MockAppSyncServer();
      await server.start();
    });

    tearDown(() => server.stop());

    test('performs the REALTIME handshake and receives subscription data',
        () async {
      final issued = <String>[];
      final link = AppSyncWebSocketLink(
        server.url,
        authProvider: countingJwtProvider(issued),
      );

      final responses = link.request(subscriptionRequest());
      final received = <Response>[];
      final subscription = responses.listen(received.add);

      await waitForCondition(
        () => server.countClientMessagesOfType('connection_init') > 0,
        message: 'server did not receive connection_init',
      );

      // The upgrade request must carry the AppSync connection auth.
      final auth = decodedConnectionAuth(server.connectionRequests.first);
      expect(auth['header']['Authorization'], 'token-1');
      expect(auth['header']['host'], '127.0.0.1');
      expect(auth['payload'], <String, dynamic>{});

      // connection_init is bare, per the documented protocol.
      final connectionInit = server.clientMessages
          .firstWhere((m) => m['type'] == 'connection_init');
      expect(connectionInit.containsKey('payload'), isFalse);

      await waitForCondition(
        () => server.countClientMessagesOfType('start') > 0,
        message: 'server did not receive start',
      );

      // The start message carries the double-encoded operation and the
      // per-message authorization.
      final start =
          server.clientMessages.firstWhere((m) => m['type'] == 'start');
      final payload = start['payload'] as Map<String, dynamic>;
      final data =
          jsonDecode(payload['data'] as String) as Map<String, dynamic>;
      expect(data['query'], contains('MockSub'));
      final authorization =
          payload['extensions']['authorization'] as Map<String, dynamic>;
      expect(authorization['host'], '127.0.0.1');
      expect(authorization['Authorization'], startsWith('token-'));

      // start_ack must not break the client; the data message must surface.
      await waitForCondition(
        () => received.isNotEmpty,
        message: 'client did not receive the subscription data',
      );
      expect(received.first.data, {'mocked': true});

      await subscription.cancel();

      // Unregistration happens with a stop message.
      await waitForCondition(
        () => server.countClientMessagesOfType('stop') > 0,
        message: 'server did not receive stop after cancel',
      );

      // AppSync has no ping/pong half-protocol: the client must not send
      // ping messages.
      expect(server.countClientMessagesOfType('ping'), 0);

      await link.dispose();
    });

    test('offers the graphql-ws subprotocol on the upgrade request', () async {
      final link = AppSyncWebSocketLink(
        server.url,
        authProvider: AppSyncApiKeyAuth('da2-key'),
      );
      final subscription = link.request(subscriptionRequest()).listen((_) {});

      await waitForCondition(
        () => server.connectionCount > 0,
        message: 'server did not see an upgrade request',
      );
      expect(server.offeredProtocols.first, contains('graphql-ws'));

      await subscription.cancel();
      await link.dispose();
    });

    test('reconnects with fresh authorization after a connection loss',
        () async {
      final issued = <String>[];
      final link = AppSyncWebSocketLink(
        server.url,
        authProvider: countingJwtProvider(issued),
        delayBetweenReconnectionAttempts: const Duration(milliseconds: 1),
      );

      final responses = link.request(subscriptionRequest());
      final received = <Response>[];
      final subscription = responses.listen(received.add);

      await waitForCondition(
        () => server.countClientMessagesOfType('start') > 0,
        message: 'server did not receive the first start',
      );
      final firstStart =
          server.clientMessages.firstWhere((m) => m['type'] == 'start');
      final firstToken = (firstStart['payload']['extensions']['authorization']
          as Map)['Authorization'] as String;

      // Kill the connection: the client must reconnect and re-register the
      // subscription with FRESH authorization (a later-issued token).
      server.forceCloseSockets();
      await waitForCondition(
        () => server.countClientMessagesOfType('start') > 1,
        message: 'server did not receive a second start after reconnect',
      );
      final starts =
          server.clientMessages.where((m) => m['type'] == 'start').toList();
      final secondToken = (starts[1]['payload']['extensions']['authorization']
          as Map)['Authorization'] as String;
      expect(
        int.parse(secondToken.substring('token-'.length)),
        greaterThan(int.parse(firstToken.substring('token-'.length))),
        reason: 'the re-registered subscription must carry a refreshed token',
      );

      // The reconnect upgrade request must also carry fresh auth.
      final secondAuth = decodedConnectionAuth(server.connectionRequests[1]);
      expect(
        int.parse((secondAuth['header']['Authorization'] as String)
            .substring('token-'.length)),
        greaterThan(0),
      );

      await subscription.cancel();
      await link.dispose();
    });

    test('recovers with fresh authorization after a handshake rejection',
        () async {
      // The first connection presents an expired token; every later one is
      // fresh, like a Cognito session refreshed after a 401.
      final issued = <String>[];
      server.rejectAuthorizationValue = 'token-1';

      final link = AppSyncWebSocketLink(
        server.url,
        authProvider: countingJwtProvider(issued),
        delayBetweenReconnectionAttempts: const Duration(milliseconds: 1),
      );

      final responses = link.request(subscriptionRequest());
      final received = <Response>[];
      final subscription = responses.listen(received.add);

      // The rejected handshake must not hang the subscription: the client
      // reconnects and the subscription still goes live.
      await waitForCondition(
        () => received.isNotEmpty,
        message: 'client did not receive the subscription data',
      );
      expect(received.first.data, {'mocked': true});

      expect(server.connectionCount, greaterThan(1));
      final acceptedAuth =
          decodedConnectionAuth(server.connectionRequests.last);
      expect(acceptedAuth['header']['Authorization'], isNot('token-1'));

      await subscription.cancel();
      await link.dispose();
    });

    test(
        'surfaces a failing auth provider on the response stream instead of '
        'hanging, and retries on reconnect', () async {
      final link = AppSyncWebSocketLink(
        server.url,
        authProvider: FlakyOperationJwtAuth(1),
        delayBetweenReconnectionAttempts: const Duration(milliseconds: 1),
      );

      final responses = link.request(subscriptionRequest());
      final received = <Response>[];
      final errors = <Object>[];
      final subscription = responses.listen(received.add, onError: errors.add);

      // The connection handshake succeeds (the provider only fails
      // per-message), so the serialization failure must surface on the
      // response stream instead of hanging the subscription.
      await waitForCondition(
        () => errors.isNotEmpty,
        message: 'the serialization failure did not surface on the stream',
      );
      expect(errors.first, isA<StateError>());
      expect((errors.first as StateError).message, 'refresh failed');

      // Deliberate aftermath: the stream stays open after the error, and a
      // reconnect — which resets the initializer — retries the registration.
      // With the provider recovered the subscription goes live; a transient
      // refresh failure is recoverable rather than terminal.
      server.forceCloseSockets();
      await waitForCondition(
        () => received.isNotEmpty,
        message: 'the subscription did not recover after the reconnect',
      );
      expect(received.first.data, {'mocked': true});

      await subscription.cancel();
      await link.dispose();
    });
  });
}
