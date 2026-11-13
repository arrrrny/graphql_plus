import 'dart:async';

import 'package:gql/language.dart';
import 'package:graphql_plus/graphql_plus.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const mutationDocument =
    r'mutation AddTodo($text: String!) { addTodo(text: $text) { id text } }';

Request mutationRequest({
  String document = mutationDocument,
  String? operationName,
  Map<String, dynamic> variables = const <String, dynamic>{},
}) =>
    Request(
      operation: Operation(
        document: parseString(document),
        operationName: operationName,
      ),
      variables: variables,
    );

/// A link that records every request it sees and answers with a canned result.
Link recordingLink(
  List<Request> seen, {
  void Function(Request request)? onRequest,
  Object? Function(Request request)? onError,
}) =>
    Link.function((request, [forward]) async* {
      seen.add(request);
      onRequest?.call(request);
      final error = onError?.call(request);
      if (error != null) {
        throw error;
      }
      yield Response(
        data: <String, dynamic>{
          'addTodo': <String, dynamic>{'id': '1'}
        },
        response: <String, dynamic>{},
      );
    });

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('OfflineMutationLink', () {
    test('a query passes through while offline', () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);

      final query = Request(
        operation: Operation(document: parseString('query { viewer { id } }')),
      );
      final responses = await link.request(query).toList();

      expect(seen, hasLength(1));
      expect(responses, hasLength(1));
      expect(link.queue.isEmpty, isTrue);
    });

    test('an online mutation is sent straight through', () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor();
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);

      await link.request(mutationRequest()).toList();

      expect(seen, hasLength(1));
      expect(link.queue.isEmpty, isTrue);
    });

    test(
        'an offline mutation is queued and fails with OfflineMutationException',
        () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);

      OfflineMutationException? failure;
      try {
        await link
            .request(mutationRequest(
              variables: <String, dynamic>{'text': 'queued'},
            ))
            .toList();
      } on OfflineMutationException catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(seen, isEmpty);
      expect(link.queue.length, 1);
      expect(failure!.mutationId, link.queue.head!.id);
      expect(failure.queueLength, 1);
    });

    test('reconnect replays the queue in order and reports the deliveries',
        () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);
      final delivered = <DeliveredMutation>[];
      final subscription = link.onDelivered.listen(delivered.add);
      addTearDown(subscription.cancel);

      await expectLater(
        link
            .request(mutationRequest(
              variables: <String, dynamic>{'text': 'first'},
            ))
            .toList(),
        throwsA(isA<OfflineMutationException>()),
      );
      await expectLater(
        link
            .request(mutationRequest(
              variables: <String, dynamic>{'text': 'second'},
            ))
            .toList(),
        throwsA(isA<OfflineMutationException>()),
      );

      monitor.goOnline();
      await waitFor(() => link.queue.isEmpty);
      await waitFor(() => delivered.length == 2);

      expect(seen.map((request) => request.variables['text']).toList(),
          ['first', 'second']);
      expect(
          delivered.map((entry) => entry.mutation.variables['text']).toList(),
          ['first', 'second']);
      expect(delivered.first.response.data, isNotNull);
    });

    test('flush sends the queued mutations one at a time, oldest first',
        () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);

      await queueWhileOffline(
        link,
        <String>['a', 'b', 'c'],
      );
      expect(link.queue.length, 3);

      final delivered = await link.flush();

      expect(delivered, 3);
      expect(seen.map((request) => request.variables['text']).toList(),
          ['a', 'b', 'c']);
      expect(link.queue.isEmpty, isTrue);
    });

    test('a transport failure keeps the mutation queued and is reported',
        () async {
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(
          <Request>[],
          onError: (_) => StateError('socket closed'),
        ),
        connectivity: monitor,
      );
      addTearDown(link.dispose);
      final failures = <OfflineMutationFailure>[];
      final subscription = link.onReplayFailure.listen(failures.add);
      addTearDown(subscription.cancel);

      await queueWhileOffline(link, <String>['a']);

      monitor.goOnline();
      await waitFor(() => failures.isNotEmpty);

      expect(failures.single.mutation.variables['text'], 'a');
      expect(failures.single.error, isA<StateError>());
      expect(link.queue.length, 1);
      expect(link.queue.head!.attempts, 1);
    });

    test('a GraphQL error response still counts as delivered', () async {
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: Link.function((request, [forward]) async* {
          yield Response(
            errors: const <GraphQLError>[
              GraphQLError(message: 'Todo is read only'),
            ],
            response: <String, dynamic>{},
          );
        }),
        connectivity: monitor,
      );
      addTearDown(link.dispose);
      final delivered = <DeliveredMutation>[];
      final subscription = link.onDelivered.listen(delivered.add);
      addTearDown(subscription.cancel);

      await queueWhileOffline(link, <String>['a']);

      monitor.goOnline();
      await waitFor(() => delivered.isNotEmpty);

      expect(link.queue.isEmpty, isTrue);
      expect(delivered.single.response.errors, hasLength(1));
    });

    test('replay carries the idempotency key of the queued entry', () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);

      await queueWhileOffline(link, <String>['a']);
      final key = link.queue.head!.idempotencyKey;

      await link.flush();

      expect(seen.single.context.entry<OfflineIdempotencyKey>()?.key, key);
    });

    test('a second connectivity event does not replay twice', () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);

      await queueWhileOffline(link, <String>['a']);

      monitor.goOnline();
      await waitFor(() => link.queue.isEmpty);
      monitor.goOffline();
      monitor.goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(seen, hasLength(1));
    });

    test('end to end: client.mutate queues offline and replays on reconnect',
        () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);
      final client = GraphQLClient(cache: getTestCache(), link: link);

      final result = await client.mutate<Object?>(
        MutationOptions<Object?>(
          document: parseString(mutationDocument),
          variables: <String, dynamic>{'text': 'from the app'},
        ),
      );

      expect(result.hasException, isTrue);
      expect(result.exception?.linkException, isA<OfflineMutationException>());
      expect(seen, isEmpty);
      expect(link.queue.length, 1);

      monitor.goOnline();
      await waitFor(() => seen.isNotEmpty);
      await waitFor(() => link.queue.isEmpty);

      expect(seen.single.variables, <String, dynamic>{'text': 'from the app'});
    });

    test('queries are never queued, whatever the document holds', () async {
      final seen = <Request>[];
      final monitor = ManualConnectivityMonitor(isOnline: false);
      final link = OfflineMutationLink(
        forward: recordingLink(seen),
        connectivity: monitor,
      );
      addTearDown(link.dispose);

      await link
          .request(
            Request(
              operation: Operation(
                document: parseString(
                  'query A { a } query B { b }',
                ),
                operationName: 'B',
              ),
            ),
          )
          .toList();

      expect(seen, hasLength(1));
      expect(link.queue.isEmpty, isTrue);
    });
  });

  group('ManualConnectivityMonitor', () {
    test('reports its state and emits only on change', () async {
      final monitor = ManualConnectivityMonitor(isOnline: false);
      addTearDown(monitor.dispose);
      final states = <bool>[];
      final subscription = monitor.onConnectivityChanged.listen(states.add);

      expect(monitor.isOnline, isFalse);

      monitor.goOnline();
      monitor.goOnline();
      monitor.goOffline();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(states, [true, false]);
      expect(monitor.isOnline, isFalse);
    });
  });
}

Future<void> queueWhileOffline(
  OfflineMutationLink link,
  List<String> texts,
) async {
  for (final text in texts) {
    await expectLater(
      link
          .request(mutationRequest(
            variables: <String, dynamic>{'text': text},
          ))
          .toList(),
      throwsA(isA<OfflineMutationException>()),
    );
  }
}
