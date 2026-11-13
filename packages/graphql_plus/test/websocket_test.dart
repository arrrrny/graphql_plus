import 'dart:async';
import 'dart:io';

import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:gql/language.dart';
import 'package:graphql_plus/graphql_plus.dart';

import './helpers.dart';
import 'mock_server/ws_echo_server.dart';

SocketClient getTestClient({
  required String wsUrl,
  StreamController<dynamic>? controller,
  bool autoReconnect = true,
  Map<String, dynamic>? customHeaders,
  Duration delayBetweenReconnectionAttempts = const Duration(milliseconds: 1),
  String protocol = GraphQLProtocol.graphqlWs,
  Stream<ToggleConnectionState>? toggleConnection,
}) =>
    SocketClient(
      wsUrl,
      protocol: protocol,
      config: SocketClientConfig(
        autoReconnect: autoReconnect,
        headers: customHeaders,
        delayBetweenReconnectionAttempts: delayBetweenReconnectionAttempts,
        initialPayload: {
          'protocol': protocol,
        },
        toggleConnection: toggleConnection,
      ),
      randomBytesForUuid: Uint8List.fromList(
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
      ),
    );

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

Future<void> main() async {
  String wsUrl = await runWebSocketServer();
  group('InitOperation', () {
    test('null payload', () {
      // ignore: deprecated_member_use_from_same_package
      final operation = InitOperation(null);
      expect(operation.toJson(), {'type': 'connection_init'});
    });
    test('simple payload', () {
      // ignore: deprecated_member_use_from_same_package
      final operation = InitOperation(42);
      expect(operation.toJson(), {'type': 'connection_init', 'payload': 42});
    });
    test('complex payload', () {
      // ignore: deprecated_member_use_from_same_package
      final operation = InitOperation({
        'value': 42,
        'nested': {
          'number': [3, 7],
          'string': ['foo', 'bar']
        }
      });
      expect(operation.toJson(), {
        'type': 'connection_init',
        'payload': {
          'value': 42,
          'nested': {
            'number': [3, 7],
            'string': ['foo', 'bar']
          }
        }
      });
    });
  });

  group('GraphQLSocketMessage.parse', () {
    test('graphql-transport-ws subprotocol with errors', () {
      const payload = [
        {
          'message': 'Cannot query field "wrongQuery" on type "Query".',
          'locations': [
            {'line': 1, 'column': 2}
          ],
          'extensions': {
            'validationError': {
              'spec': 'https://spec.graphql.org/draft/#sec-Field-Selections',
            }
          }
        }
      ];

      const message = {'id': 'message-id', 'type': 'error', 'payload': payload};
      final parsed = GraphQLSocketMessage.parse(jsonEncode(message));
      expect(parsed, isA<SubscriptionError>());
      expect(parsed.toJson(), message);
    });

    test('graphql-ws apollo subprotocol with errors', () {
      const payload = {
        'message': 'Cannot query field "wrongQuery" on type "Query".',
        'locations': [
          {'line': 1, 'column': 2}
        ],
        'extensions': {
          'validationError': {
            'spec': 'https://spec.graphql.org/draft/#sec-Field-Selections',
          }
        }
      };
      const message = {'id': 'message-id', 'type': 'error', 'payload': payload};
      final parsed = GraphQLSocketMessage.parse(jsonEncode(message));
      expect(parsed, isA<SubscriptionError>());
      expect(parsed.toJson(), message);
    });
  });

  group('SocketClient without payload', () {
    late SocketClient socketClient;
    StreamController<dynamic> controller;
    final expectedMessage = r'{'
        r'"type":"start","id":"01020304-0506-4708-890a-0b0c0d0e0f10",'
        r'"payload":{"operationName":null,"variables":{},"query":"subscription {\n  \n}"}'
        r'}';
    setUp(overridePrint((log) {
      controller = StreamController(sync: true);
      socketClient = getTestClient(controller: controller, wsUrl: wsUrl);
    }));
    tearDown(overridePrint(
      (log) => socketClient.dispose(),
    ));
    test('connection', () async {
      await expectLater(
        socketClient.connectionState.asBroadcastStream(),
        emitsInOrder(
          [
            SocketConnectionState.connecting,
            SocketConnectionState.connected,
          ],
        ),
      );
    });
    test('disconnect via dispose', () async {
      // First wait for connection to complete
      await expectLater(
        socketClient.connectionState.asBroadcastStream(),
        emitsInOrder(
          [
            SocketConnectionState.connecting,
            SocketConnectionState.connected,
          ],
        ),
      );

      // We need to begin waiting on the connectionState
      // before we issue the command to disconnect; otherwise
      // it can reconnect so fast that it will be reconnected
      // by the time that the expectLater check is initiated.
      await overridePrint((_) async {
        Timer(const Duration(milliseconds: 20), () async {
          await socketClient.dispose();
        });
      })();
      // The connectionState BehaviorController emits the current state
      // to any new listener, so we expect it to start in the connected
      // state and transition to notConnected because of dispose.
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
        ]),
      );

      // Have to wait for socket close to be fully processed after we reach
      // the notConnected state, including updating channel with close code.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The websocket should be in a fully closed state at this point,
      // we should have a confirmed close code in the channel.
      expect(socketClient.socketChannel, isNotNull);
      // FIXME: as per https://github.com/dart-lang/web_socket_channel/issues/383, closeCode is not being sent in version 3.0.1
      // however, closeCode is not import in graphql-flutter. Connection is closed as expected. We can merely remove it from this test.
      // expect(socketClient.socketChannel!.closeCode, isNotNull);
    });
    test('subscription data', () async {
      final payload = Request(
        operation: Operation(document: parseString('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);
      await socketClient.connectionState
          .where((state) => state == SocketConnectionState.connected)
          .first;

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'data',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ]
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(null)),
            response: {
              "type": "data",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ]
            },
          ),
        ),
      );
    });
    test('subscription data with extensions', () async {
      final payload = Request(
        operation: Operation(document: parseString('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);
      await socketClient.connectionState
          .where((state) => state == SocketConnectionState.connected)
          .first;

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'data',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ],
            'extensions': {'extensionKey': 'extensionValue'},
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(<dynamic, dynamic>{
              'extensionKey': 'extensionValue',
            })),
            response: {
              "type": "data",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ],
              "extensions": {'extensionKey': 'extensionValue'},
            },
          ),
        ),
      );
    });
    test('resubscribe', () async {
      final payload = Request(
        operation: Operation(document: gql('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      await overridePrint((_) async {
        socketClient.onConnectionLost();
      })();

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.notConnected,
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'data',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ]
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(null)),
            response: {
              "type": "data",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ]
            },
          ),
        ),
      );
    });
    test('resubscribe after server disconnect', () async {
      final payload = Request(
        operation: Operation(document: gql('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      // We need to begin waiting on the connectionState
      // before we issue the command to disconnect; otherwise
      // it can reconnect so fast that it will be reconnected
      // by the time that the expectLater check is initiated.
      Timer(const Duration(milliseconds: 20), () async {
        socketClient.socketChannel!.sink.add(forceDisconnectCommand);
      });
      // The connectionState BehaviorController emits the current state
      // to any new listener, so we expect it to start in the connected
      // state, transition to notConnected, and then reconnect after that.
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'data',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ]
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(null)),
            response: {
              "type": "data",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ]
            },
          ),
        ),
      );
    });
  }, tags: "integration");

  group('SocketClient without payload graphql-transport-ws', () {
    late SocketClient socketClient;
    StreamController<dynamic> controller;
    final expectedMessage = r'{'
        r'"type":"subscribe","id":"01020304-0506-4708-890a-0b0c0d0e0f10",'
        r'"payload":{"operationName":null,"variables":{},"query":"subscription {\n  \n}"}'
        r'}';
    late PublishSubject<ToggleConnectionState> toggleConnection;

    setUp(overridePrint((log) {
      toggleConnection = new PublishSubject<ToggleConnectionState>();

      controller = StreamController(sync: true);
      socketClient = getTestClient(
        controller: controller,
        protocol: GraphQLProtocol.graphqlTransportWs,
        wsUrl: wsUrl,
        toggleConnection: toggleConnection,
      );
    }));
    tearDown(overridePrint(
      (log) => socketClient.dispose(),
    ));
    test('connection graphql-transport-ws', () async {
      await expectLater(
        socketClient.connectionState.asBroadcastStream(),
        emitsInOrder(
          [
            SocketConnectionState.connecting,
            SocketConnectionState.handshake,
            SocketConnectionState.connected,
          ],
        ),
      );
    });
    test('disconnect via dispose graphql-transport-ws', () async {
      // First wait for connection to complete
      await expectLater(
        socketClient.connectionState.asBroadcastStream(),
        emitsInOrder(
          [
            SocketConnectionState.connecting,
            SocketConnectionState.handshake,
            SocketConnectionState.connected,
          ],
        ),
      );

      // We need to begin waiting on the connectionState
      // before we issue the command to disconnect; otherwise
      // it can reconnect so fast that it will be reconnected
      // by the time that the expectLater check is initiated.
      await overridePrint((_) async {
        Timer(const Duration(milliseconds: 20), () async {
          await socketClient.dispose();
        });
      })();
      // The connectionState BehaviorController emits the current state
      // to any new listener, so we expect it to start in the connected
      // state and transition to notConnected because of dispose.
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
        ]),
      );

      // Have to wait for socket close to be fully processed after we reach
      // the notConnected state, including updating channel with close code.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The websocket should be in a fully closed state at this point,
      // we should have a confirmed close code in the channel.
      expect(socketClient.socketChannel, isNotNull);
      // as per https://github.com/dart-lang/web_socket_channel/issues/383, closeCode is not being sent in version 3.0.1
      // however, closeCode is not import in graphql-flutter. Connection is closed as expected. We can merely remove it from this test.
      // expect(socketClient.socketChannel!.closeCode, isNotNull);
    });
    test('subscription data graphql-transport-ws', () async {
      final payload = Request(
        operation: Operation(document: parseString('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);
      await socketClient.connectionState
          .where((state) => state == SocketConnectionState.connected)
          .first;

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'next',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ]
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(null)),
            response: {
              "type": "next",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ]
            },
          ),
        ),
      );
    });
    test('resubscribe', () async {
      final payload = Request(
        operation: Operation(document: gql('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.handshake,
          SocketConnectionState.connected,
        ]),
      );

      await overridePrint((_) async {
        socketClient.onConnectionLost();
      })();

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.notConnected,
          SocketConnectionState.connecting,
          SocketConnectionState.handshake,
          SocketConnectionState.connected,
        ]),
      );

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'next',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ]
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(null)),
            response: {
              "type": "next",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ]
            },
          ),
        ),
      );
    });
    test('resubscribe after server disconnect', () async {
      final payload = Request(
        operation: Operation(document: gql('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.handshake,
          SocketConnectionState.connected,
        ]),
      );

      // We need to begin waiting on the connectionState
      // before we issue the command to disconnect; otherwise
      // it can reconnect so fast that it will be reconnected
      // by the time that the expectLater check is initiated.
      Timer(const Duration(milliseconds: 20), () async {
        socketClient.socketChannel!.sink.add(forceDisconnectCommand);
      });
      // The connectionState BehaviorController emits the current state
      // to any new listener, so we expect it to start in the connected
      // state, transition to notConnected, and then reconnect after that.
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
          SocketConnectionState.connecting,
          SocketConnectionState.handshake,
          SocketConnectionState.connected,
        ]),
      );

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'next',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ]
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(null)),
            response: {
              "type": "next",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ]
            },
          ),
        ),
      );
    });

    test('resubscribe after server disconnect and resubscription not paused',
        () async {
      final payload = Request(
        operation: Operation(document: gql('subscription {}')),
      );
      final waitForConnection = true;
      final subscriptionDataStream =
          socketClient.subscribe(payload, waitForConnection);

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.handshake,
          SocketConnectionState.connected,
        ]),
      );

      Timer(const Duration(milliseconds: 10), () async {
        toggleConnection.add(ToggleConnectionState.disconnect);
      });

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
        ]),
      );

      Timer(const Duration(milliseconds: 10), () async {
        toggleConnection.add(ToggleConnectionState.connect);
      });

      // The connectionState BehaviorController emits the current state
      // to any new listener, so we expect it to start in the connected
      // state, transition to notConnected, and then reconnect after that.
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.notConnected,
          SocketConnectionState.connecting,
          SocketConnectionState.handshake,
          SocketConnectionState.connected,
        ]),
      );

      // ignore: unawaited_futures
      socketClient.socketChannel!.stream
          .where((message) => message == expectedMessage)
          .first
          .then((_) {
        socketClient.socketChannel!.sink.add(jsonEncode({
          'type': 'next',
          'id': '01020304-0506-4708-890a-0b0c0d0e0f10',
          'payload': {
            'data': {'foo': 'bar'},
            'errors': [
              {'message': 'error and data can coexist'}
            ]
          }
        }));
      });

      await expectLater(
        subscriptionDataStream,
        emits(
          // todo should ids be included in response context? probably '01020304-0506-4708-890a-0b0c0d0e0f10'
          Response(
            data: {'foo': 'bar'},
            errors: [
              GraphQLError(message: 'error and data can coexist'),
            ],
            context: Context().withEntry(ResponseExtensions(null)),
            response: {
              "type": "next",
              "data": {"foo": "bar"},
              "errors": [
                {"message": "error and data can coexist"}
              ]
            },
          ),
        ),
      );
    });
  }, tags: "integration");

  group('SocketClient without autoReconnect', () {
    late SocketClient socketClient;
    StreamController<dynamic> controller;
    setUp(overridePrint((log) {
      controller = StreamController(sync: true);
      socketClient = getTestClient(
          controller: controller, wsUrl: wsUrl, autoReconnect: false);
    }));
    tearDown(overridePrint(
      (log) => socketClient.dispose(),
    ));
    test('server disconnect', () async {
      final payload = Request(
        operation: Operation(document: gql('subscription {}')),
      );
      final waitForConnection = true;
      var subscription = socketClient.subscribe(payload, waitForConnection);
      var isEmpty = subscription.isEmpty;

      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      Timer(const Duration(milliseconds: 20), () async {
        socketClient.socketChannel!.sink.add(forceDisconnectCommand);
      });
      // Same strategy as elsewhere, start expecting the state on the
      // stream before the disconnect actually happens...
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
        ]),
      );

      expect(
          socketClient.socketChannel!.closeCode, WebSocketStatus.normalClosure);

      expect(await isEmpty.timeout(const Duration(seconds: 1)), true);
    });
  }, tags: "integration");

  group('SocketClient with const payload', () {
    late SocketClient socketClient;
    const initPayload = {'token': 'mytoken'};

    setUp(overridePrint((log) {
      socketClient = SocketClient(
        wsUrl,
        config: SocketClientConfig(initialPayload: () => initPayload),
      );
    }));

    tearDown(overridePrint(
      (log) => expectLater(
        socketClient.dispose().timeout(Duration(seconds: 1)),
        completion(null),
      ),
    ));

    test('connection', () async {
      await socketClient.connectionState
          .where((state) => state == SocketConnectionState.connected)
          .first;

      await expectLater(
          socketClient.socketChannel!.stream.map((s) {
            return jsonDecode(s as String)['payload'];
          }),
          emits(initPayload));
    });
  });

  group('SocketClient with future payload', () {
    late SocketClient socketClient;
    const initPayload = {'token': 'mytoken'};

    setUp(overridePrint((log) {
      socketClient = SocketClient(
        wsUrl,
        config: SocketClientConfig(
          initialPayload: () async {
            await Future<void>.delayed(Duration(seconds: 3));
            return initPayload;
          },
        ),
      );
    }));

    tearDown(overridePrint((log) async {
      await socketClient.dispose();
    }));

    test('connection', () async {
      await socketClient.connectionState
          .where((state) => state == SocketConnectionState.connected)
          .first;

      await expectLater(
        socketClient.socketChannel!.stream.map((s) {
          return jsonDecode(s as String)['payload'];
        }),
        emits(initPayload),
      );
    });

    /*
    FIXME: Testing the correct header in the request
    group('SocketClient with custom headers with const payload', () {
      const customHeaders = {'myHeader': 'myHeader'};

      setUp(overridePrint((log) {
        socketClient = getTestClient(wsUrl: wsUrl, customHeaders: customHeaders);
      }));

      test('check header', () async {
        await socketClient.connectionState
            .where((state) => state == SocketConnectionState.notConnected)
            .first;
      });
    });
    */
  });

  group('SocketClient with dynamic payload', () {
    late SocketClient socketClient;

    var _token = 'mytoken';
    var getToken = () => _token;

    setUp(overridePrint((log) {
      socketClient = SocketClient(
        wsUrl,
        protocol: GraphQLProtocol.graphqlWs,
        config: SocketClientConfig(
          delayBetweenReconnectionAttempts: const Duration(milliseconds: 1),
          initialPayload: () =>
              {'token': getToken(), 'protocol': GraphQLProtocol.graphqlWs},
          onConnectionLost: (code, reason) async {
            if (code == 4001) {
              _token = 'mytoken2';
            }

            return Duration.zero;
          },
        ),
      );
    }));

    tearDown(overridePrint(
      (log) => socketClient.dispose(),
    ));

    test('resubscribe with new auth token', () async {
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      await expectLater(
          socketClient.socketChannel!.stream.map((s) {
            return jsonDecode(s as String)['payload']['token'];
          }),
          emits('mytoken'));

      // We need to begin waiting on the connectionState
      // before we issue the command to disconnect; otherwise
      // it can reconnect so fast that it will be reconnected
      // by the time that the expectLater check is initiated.
      Timer(const Duration(milliseconds: 20), () async {
        socketClient.socketChannel!.sink.add(forceAuthDisconnectCommand);
      });
      // The connectionState BehaviorController emits the current state
      // to any new listener, so we expect it to start in the connected
      // state, transition to notConnected, and then reconnect after that.
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      await socketClient.connectionState
          .where((state) => state == SocketConnectionState.connected)
          .first;

      await expectLater(
          socketClient.socketChannel!.stream.map((s) {
            return jsonDecode(s as String)['payload']['token'];
          }),
          emits('mytoken2'));
    });
  });

  group('SocketClient with dynamic headers', () {
    late SocketClient socketClient;
    final List<String> serverSeenAuthorization = [];
    late String wsRecorderUrl;
    var _token = 'Bearer token-1';

    setUpAll(() async {
      wsRecorderUrl = await runWebSocketServer(
        port: 5601,
        onConnectionHeaders: (headers) {
          final authorization = headers[HttpHeaders.authorizationHeader]?.first;
          serverSeenAuthorization.add(authorization ?? '');
        },
      );
    });

    setUp(overridePrint((log) {
      socketClient = SocketClient(
        wsRecorderUrl,
        protocol: GraphQLProtocol.graphqlWs,
        config: SocketClientConfig(
          delayBetweenReconnectionAttempts: const Duration(milliseconds: 1),
          getHeaders: () => {'Authorization': _token},
          onConnectionLost: (code, reason) async {
            if (code == 4001) {
              _token = 'Bearer token-2';
            }

            return Duration.zero;
          },
        ),
      );
    }));

    tearDown(overridePrint(
      (log) => socketClient.dispose(),
    ));

    test('refreshes authorization header on reconnect', () async {
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      await waitForCondition(
        () => serverSeenAuthorization.isNotEmpty,
        message: 'server did not observe the first connection attempt',
      );
      expect(serverSeenAuthorization.last, 'Bearer token-1');

      Timer(const Duration(milliseconds: 20), () async {
        socketClient.socketChannel!.sink.add(forceAuthDisconnectCommand);
      });
      await expectLater(
        socketClient.connectionState,
        emitsInOrder([
          SocketConnectionState.connected,
          SocketConnectionState.notConnected,
          SocketConnectionState.connecting,
          SocketConnectionState.connected,
        ]),
      );

      await waitForCondition(
        () => serverSeenAuthorization.length >= 2,
        message: 'server did not observe the reconnect attempt',
      );
      expect(serverSeenAuthorization.last, 'Bearer token-2');
      expect(serverSeenAuthorization.first, 'Bearer token-1');
    });

    test('resolvedHeaders accepts literal maps, sync and async callbacks',
        () async {
      final literal = SocketClientConfig(headers: {'a': 'b'});
      expect(await literal.resolvedHeaders, {'a': 'b'});

      final sync = SocketClientConfig(
          getHeaders: () => {'Authorization': 'Bearer sync'});
      expect(await sync.resolvedHeaders, {'Authorization': 'Bearer sync'});

      final asyncCfg = SocketClientConfig(
          getHeaders: () async => {'Authorization': 'Bearer async'});
      expect(await asyncCfg.resolvedHeaders, {'Authorization': 'Bearer async'});

      final nullHeaders = SocketClientConfig();
      expect(await nullHeaders.resolvedHeaders, isNull);
    });

    test('getHeaders result takes precedence over literal headers', () async {
      final precedence = SocketClientConfig(
        headers: {'a': 'b'},
        getHeaders: () => {'Authorization': 'Bearer fresh'},
      );
      expect(
          await precedence.resolvedHeaders, {'Authorization': 'Bearer fresh'});

      final fallback = SocketClientConfig(
        headers: {'a': 'b'},
        getHeaders: () => null,
      );
      expect(await fallback.resolvedHeaders, {'a': 'b'});
    });
  });

  group('SocketClient graphql-transport-ws keepalive', () {
    test('keeps pinging a peer that never answers with pong', () async {
      var pings = 0;
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));

      server.listen((HttpRequest request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((data) {
          final message = json.decode(data.toString());
          switch (message['type']) {
            case 'connection_init':
              socket.add(json.encode({'type': 'connection_ack'}));
              break;
            case 'ping':
              // Count it and deliberately never answer with `pong`.
              pings++;
              break;
          }
        });
      });

      final client = SocketClient(
        'ws://127.0.0.1:${server.port}',
        protocol: GraphQLProtocol.graphqlTransportWs,
        config: SocketClientConfig(
          autoReconnect: false,
          inactivityTimeout: const Duration(milliseconds: 200),
        ),
      );
      addTearDown(client.dispose);

      await client.connectionState
          .where((state) => state == SocketConnectionState.connected)
          .first;

      // Several ping intervals, with no pong ever sent. Before the fix the timer
      // was one-shot, so exactly one ping was sent and the connection then had no
      // keepalive at all.
      await Future<void>.delayed(const Duration(milliseconds: 750));

      expect(pings, greaterThan(1),
          reason: 'a keepalive must not depend on being acknowledged');
    });
  });

  group('SocketClient keepalive watchdog', () {
    Future<HttpServer> startServer({
      required void Function(WebSocket socket, dynamic data) onMessage,
    }) async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((data) => onMessage(socket, data));
      });
      return server;
    }

    test(
      'graphql-ws: a peer that never sends ConnectionKeepAlive is left connected',
      () async {
        final server = await startServer(
          onMessage: (socket, data) {
            final message = json.decode(data.toString());
            if (message['type'] == 'connection_init') {
              socket.add(json.encode({'type': 'connection_ack'}));
            }
            // Deliberately never sends {"type": "ka"} — the Apollo Server 3+/NestJS case.
          },
        );

        final client = SocketClient(
          'ws://127.0.0.1:${server.port}',
          protocol: GraphQLProtocol.graphqlWs,
          config: SocketClientConfig(
            autoReconnect: false,
            inactivityTimeout: const Duration(milliseconds: 200),
          ),
        );
        addTearDown(client.dispose);

        await client.connectionState
            .where((state) => state == SocketConnectionState.connected)
            .first;

        // Well past the inactivity timeout. Before the fix the watchdog force-closed
        // the socket here, which with autoReconnect on produces the connect/disconnect
        // loop reported in #15. `closeCode` is not a usable signal (it is not set
        // synchronously on a local close), so assert on the connection state instead.
        var sawDisconnect = false;
        final subscription = client.connectionState.listen((state) {
          if (state == SocketConnectionState.notConnected) {
            sawDisconnect = true;
          }
        });
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await subscription.cancel();

        expect(sawDisconnect, isFalse,
            reason: 'a healthy but idle connection must not be force-closed');
      },
    );

    test(
      'graphql-ws: a peer whose ConnectionKeepAlive stops is still closed',
      () async {
        Timer? kaTimer;
        var stopKeepAlives = false;
        final server = await startServer(
          onMessage: (socket, data) {
            final message = json.decode(data.toString());
            if (message['type'] == 'connection_init') {
              // Created before the ack, so the timer exists by the time the test
              // observes `connected` and can cancel it deterministically.
              kaTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
                if (!stopKeepAlives) {
                  socket.add(json.encode({'type': 'ka'}));
                }
              });
              socket.add(json.encode({'type': 'connection_ack'}));
            }
          },
        );
        addTearDown(() => kaTimer?.cancel());

        final client = SocketClient(
          'ws://127.0.0.1:${server.port}',
          protocol: GraphQLProtocol.graphqlWs,
          config: SocketClientConfig(
            autoReconnect: false,
            inactivityTimeout: const Duration(milliseconds: 400),
          ),
        );
        addTearDown(client.dispose);

        await client.connectionState
            .where((state) => state == SocketConnectionState.connected)
            .first;

        // Let a few keepalives through so the watchdog arms, then stop them.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        stopKeepAlives = true;
        kaTimer?.cancel();

        // The watchdog must still fire once the peer stops sending keepalives.
        await expectLater(
          client.connectionState
              .where((state) => state == SocketConnectionState.notConnected)
              .first
              .timeout(const Duration(seconds: 5)),
          completion(SocketConnectionState.notConnected),
        );
      },
    );

    test(
      'graphql-ws: a peer whose first ConnectionKeepAlive arrives late is still closed',
      () async {
        // The first ka lands after inactivityTimeout. `Stream.timeout` would have fired
        // and closed its own stream here, permanently disarming the watchdog, so a
        // later death would go unnoticed. A resettable timer must arm on that first ka.
        Timer? kaTimer;
        final server = await startServer(
          onMessage: (socket, data) {
            final message = json.decode(data.toString());
            if (message['type'] == 'connection_init') {
              socket.add(json.encode({'type': 'connection_ack'}));
              kaTimer = Timer(const Duration(milliseconds: 500), () {
                socket.add(json.encode({'type': 'ka'}));
                // Then every 50ms, so the watchdog is demonstrably armed.
                kaTimer = Timer.periodic(
                  const Duration(milliseconds: 50),
                  (_) => socket.add(json.encode({'type': 'ka'})),
                );
              });
            }
          },
        );
        addTearDown(() => kaTimer?.cancel());

        final client = SocketClient(
          'ws://127.0.0.1:${server.port}',
          protocol: GraphQLProtocol.graphqlWs,
          config: SocketClientConfig(
            autoReconnect: false,
            inactivityTimeout: const Duration(milliseconds: 200),
          ),
        );
        addTearDown(client.dispose);

        await client.connectionState
            .where((state) => state == SocketConnectionState.connected)
            .first;

        // Let the late first ka land and the watchdog arm, then stop the keepalives.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        kaTimer?.cancel();

        await expectLater(
          client.connectionState
              .where((state) => state == SocketConnectionState.notConnected)
              .first
              .timeout(const Duration(seconds: 5)),
          completion(SocketConnectionState.notConnected),
        );
      },
    );
  });
}
