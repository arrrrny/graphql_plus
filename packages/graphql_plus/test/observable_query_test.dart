import 'package:test/test.dart';
import 'package:mockito/mockito.dart';

import 'package:graphql_plus/graphql_plus.dart';
import 'package:gql/language.dart';

import './helpers.dart';

void main() {
  const String readSingle = r'''
    query ReadSingle() {
      single() {
        id,
        __typename,
        name
      }
    }
  ''';
  const data = {
    'single': {
      'id': '1',
      '__typename': 'Single',
      'name': 'initialQueryName',
    },
  };
  const pollDuration = Duration(milliseconds: 20);

  // The poller tests wait `pollDuration * 2.1` and then close. The 1s ceiling this
  // replaces was not enough under full-suite load (dart test runs files in parallel
  // isolates), so the tests timed out intermittently on a green tree. They are fast;
  // the budget is just not allowed to be the thing that fails.
  const pollTestTimeout = Timeout(Duration(seconds: 30));

  final queryResponseMatcher = isA<QueryResult>().having(
    (result) => result.data!['single']['name'],
    'name',
    'initialQueryName',
  );

  late MockLink link;
  late GraphQLClient client;

  group('observable query ', () {
    setUp(() {
      link = MockLink();

      client = GraphQLClient(
        cache: getTestCache(),
        link: link,
      );

      final queryResponse = Response(data: data, response: {});
      when(
        link.request(any),
      ).thenAnswer(
        (_) => Stream.fromIterable(
          [queryResponse],
        ),
      );
    });
    test('can start poller', () async {
      final observable = client.watchQuery(
        WatchQueryOptions(
          document: parseString(readSingle),
        ),
      );
      final expectation = expectLater(
        observable.stream,
        emitsInOrder(
          [queryResponseMatcher, queryResponseMatcher, emitsDone],
        ),
      );
      observable.startPolling(pollDuration);
      await Future<void>.delayed(pollDuration * 2.1);
      observable.close();
      await expectation;
    }, timeout: pollTestTimeout);
    test('can stop poller', () async {
      final observable = client.watchQuery(
        WatchQueryOptions(
          document: parseString(readSingle),
        ),
      );
      final expectation = expectLater(
        observable.stream,
        neverEmits(
          isA<QueryResult>().having(
            (result) => result.data!['single']['name'],
            'name',
            'initialQueryName',
          ),
        ),
      );
      observable.startPolling(pollDuration);
      observable.stopPolling();
      await Future<void>.delayed(pollDuration * 2.1);
      observable.close();
      await expectation;
    }, timeout: pollTestTimeout);
    test('can deduplicate startPolling calls with the same duration', () async {
      final observable = client.watchQuery(
        WatchQueryOptions(
          document: parseString(readSingle),
        ),
      );
      final expectation = expectLater(
        observable.stream,
        emitsInOrder(
          [queryResponseMatcher, queryResponseMatcher, emitsDone],
        ),
      );
      observable.startPolling(pollDuration);
      observable.startPolling(pollDuration);
      observable.startPolling(pollDuration);
      await Future<void>.delayed(pollDuration * 2.1);
      observable.close();
      await expectation;
    }, timeout: pollTestTimeout);
    test('can deduplicate startPolling calls with different durations',
        () async {
      final observable = client.watchQuery(
        WatchQueryOptions(
          document: parseString(readSingle),
        ),
      );
      final expectation = expectLater(
        observable.stream,
        emitsInOrder(
          [
            queryResponseMatcher,
            queryResponseMatcher,
            queryResponseMatcher,
            emitsDone
          ],
        ),
      );
      observable.startPolling(Duration(milliseconds: 10));
      observable.startPolling(Duration(milliseconds: 20));
      observable.startPolling(Duration(milliseconds: 30));
      observable.startPolling(pollDuration);
      await Future<void>.delayed(pollDuration * 3.1);
      observable.close();
      await expectation;
    }, timeout: pollTestTimeout);
    test('can stop pollers in quick succession', () async {
      final observable = client.watchQuery(
        WatchQueryOptions(
          document: parseString(readSingle),
        ),
      );
      final expectation = expectLater(
        observable.stream,
        emitsInOrder(
          [
            queryResponseMatcher,
            queryResponseMatcher,
            queryResponseMatcher,
            emitsDone
          ],
        ),
      );
      observable.startPolling(pollDuration);
      observable.stopPolling();
      observable.startPolling(pollDuration);
      observable.stopPolling();
      observable.startPolling(pollDuration);
      await Future<void>.delayed(pollDuration * 3.1);
      observable.close();
      await expectation;
    }, timeout: pollTestTimeout);
  });
}
