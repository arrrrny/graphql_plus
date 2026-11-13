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

  // The poller tests used to be ceiling-bound: the 1s budget this replaces was not
  // enough under full-suite load (dart test runs files in parallel isolates), so
  // the tests timed out intermittently on a green tree. They are fast; the budget
  // is just not allowed to be the thing that fails.
  const pollTestTimeout = Timeout(Duration(seconds: 30));

  // A matcher that cannot complete is a real failure, not a slow machine. Bound
  // the await itself so a stuck stream reports in seconds instead of at the outer
  // ceiling — `close()` returns early on the `sideEffectsPending` path, so
  // "never emits done" is a reachable hang, not a hypothetical one.
  const pollExpectationTimeout = Duration(seconds: 5);

  // Only the "stopped" test needs a window: it asserts the *absence* of results,
  // so it has to give a poller that was never stopped time to fire.
  final pollSilenceWindow = pollDuration * 2;

  final queryResponseMatcher = isA<QueryResult>().having(
    (result) => result.data!['single']['name'],
    'name',
    'initialQueryName',
  );

  // A lower bound, not an exact count. `emitsInOrder` completes as soon as the
  // last matcher matches, and without a trailing `emitsDone` an extra tick cannot
  // fail the test; the await below is on the matcher rather than on a fixed
  // multiple of the poll interval, so the number of results the test depends on is
  // never decided by which side of a `Timer.periodic` tick `close()` lands on.
  Matcher emitsResults(int count) =>
      emitsInOrder(List<Matcher>.filled(count, queryResponseMatcher));

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
        emitsResults(2),
      );
      observable.startPolling(pollDuration);
      await expectation.timeout(pollExpectationTimeout);
      observable.close();
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
      await Future<void>.delayed(pollSilenceWindow);
      observable.close();
      await expectation.timeout(pollExpectationTimeout);
    }, timeout: pollTestTimeout);
    test('can deduplicate startPolling calls with the same duration', () async {
      final observable = client.watchQuery(
        WatchQueryOptions(
          document: parseString(readSingle),
        ),
      );
      final expectation = expectLater(
        observable.stream,
        emitsResults(2),
      );
      observable.startPolling(pollDuration);
      observable.startPolling(pollDuration);
      observable.startPolling(pollDuration);
      await expectation.timeout(pollExpectationTimeout);
      observable.close();
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
        emitsResults(3),
      );
      observable.startPolling(Duration(milliseconds: 10));
      observable.startPolling(Duration(milliseconds: 20));
      observable.startPolling(Duration(milliseconds: 30));
      observable.startPolling(pollDuration);
      await expectation.timeout(pollExpectationTimeout);
      observable.close();
    }, timeout: pollTestTimeout);
    test('can stop pollers in quick succession', () async {
      final observable = client.watchQuery(
        WatchQueryOptions(
          document: parseString(readSingle),
        ),
      );
      final expectation = expectLater(
        observable.stream,
        emitsResults(3),
      );
      observable.startPolling(pollDuration);
      observable.stopPolling();
      observable.startPolling(pollDuration);
      observable.stopPolling();
      observable.startPolling(pollDuration);
      await expectation.timeout(pollExpectationTimeout);
      observable.close();
    }, timeout: pollTestTimeout);
  });
}
