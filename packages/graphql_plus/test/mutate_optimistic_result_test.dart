import 'dart:async';

import 'package:graphql_plus/graphql_plus.dart';
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import './helpers.dart';

/// [GraphQLCache.inflightOptimisticTransactions] is `@protected`, so a test can
/// only read it from inside a subclass.
class _CountingCache extends GraphQLCache {
  int get inflightOptimisticTransactions =>
      super.inflightOptimisticTransactions;
}

void main() {
  const String writeSingle = r'''
    mutation WriteSingle($id: ID!, $name: String!) {
      updateSingle(id: $id, name: $name) {
        id,
        __typename,
        name
      }
    }
  ''';

  const String readSingle = r'''
    query ReadSingle {
      single {
        id,
        __typename,
        name
      }
    }
  ''';

  final DocumentNode writeSingleDocument = parseString(writeSingle);
  final DocumentNode readSingleDocument = parseString(readSingle);

  Response updateSingleResponse(String name, {String id = '1'}) => Response(
        data: <String, dynamic>{
          'updateSingle': {
            'id': id,
            '__typename': 'Single',
            'name': name,
          },
        },
        response: {},
      );

  Request writeSingleRequest(Map<String, dynamic> variables) => Request(
        operation: Operation(document: writeSingleDocument),
        variables: variables,
      );

  final Request readSingleRequest =
      Request(operation: Operation(document: readSingleDocument));

  test('update is invoked with the optimistic result before the network one',
      () async {
    final MockLink link = MockLink();
    final GraphQLClient client =
        GraphQLClient(link: link, cache: GraphQLCache());

    when(link.request(any)).thenAnswer(
      (_) => Stream.fromIterable([updateSingleResponse('networkName')]),
    );

    final List<QueryResult<Object?>?> updates = [];
    final List<String?> optimisticCacheReads = [];
    final List<dynamic> completed = [];

    final QueryResult<Object?> result = await client.mutate<Object?>(
      MutationOptions<Object?>(
        document: writeSingleDocument,
        variables: {'id': '1', 'name': 'optimisticName'},
        optimisticResult: updateSingleResponse('optimisticName').data,
        onCompleted: (dynamic data) => completed.add(data),
        update: (GraphQLDataProxy cache, QueryResult<Object?>? result) {
          updates.add(result);
          if (result!.isOptimistic) {
            // the optimistic pass must be able to read its own patch back
            optimisticCacheReads.add(
              cache.readQuery(
                writeSingleRequest({'id': '1', 'name': 'optimisticName'}),
                optimistic: true,
              )?['updateSingle']?['name'] as String?,
            );
          }
        },
      ),
    );

    expect(result.data!['updateSingle']['name'], 'networkName');
    expect(updates.length, 2);
    expect(updates.first!.isOptimistic, isTrue);
    expect(updates.first!.data!['updateSingle']['name'], 'optimisticName');
    expect(updates.last!.isOptimistic, isFalse);
    expect(updates.last!.data!['updateSingle']['name'], 'networkName');
    // only the network result may reach onCompleted — never the optimistic one
    expect(completed.length, 1);
    expect(
      (completed.single as Map<String, dynamic>)['updateSingle'],
      {'id': '1', '__typename': 'Single', 'name': 'networkName'},
    );
    // the optimistic patch is read back through the proxy the callback got
    expect(optimisticCacheReads, ['optimisticName']);
    // ...and it is gone once the network result has settled
    expect(
      client.cache.readQuery(
        writeSingleRequest({'id': '1', 'name': 'optimisticName'}),
        optimistic: true,
      )?['updateSingle']?['name'],
      'networkName',
    );
  });

  test(
      'update runs once with the network result when there is no optimistic '
      'result', () async {
    final MockLink link = MockLink();
    final GraphQLClient client =
        GraphQLClient(link: link, cache: GraphQLCache());

    when(link.request(any)).thenAnswer(
      (_) => Stream.fromIterable([updateSingleResponse('networkName')]),
    );

    final List<QueryResult<Object?>?> updates = [];
    await client.mutate<Object?>(
      MutationOptions<Object?>(
        document: writeSingleDocument,
        variables: {'id': '1', 'name': 'networkName'},
        update: (GraphQLDataProxy cache, QueryResult<Object?>? result) {
          updates.add(result);
        },
      ),
    );

    expect(updates.length, 1);
    expect(updates.single!.isOptimistic, isFalse);
    expect(updates.single!.data!['updateSingle']['name'], 'networkName');
  });

  test('a failed network mutation still reconciles the optimistic update',
      () async {
    final MockLink link = MockLink();
    final GraphQLClient client =
        GraphQLClient(link: link, cache: GraphQLCache());

    when(link.request(any)).thenAnswer(
      (_) => Stream<Response>.error(Exception('network down')),
    );

    final List<QueryResult<Object?>?> updates = [];
    final List<dynamic> completed = [];
    final List<dynamic> errors = [];
    final QueryResult<Object?> result = await client.mutate<Object?>(
      MutationOptions<Object?>(
        document: writeSingleDocument,
        variables: {'id': '1', 'name': 'optimisticName'},
        optimisticResult: updateSingleResponse('optimisticName').data,
        onCompleted: (dynamic data) => completed.add(data),
        onError: (dynamic error) => errors.add(error),
        update: (GraphQLDataProxy cache, QueryResult<Object?>? result) {
          updates.add(result);
        },
      ),
    );

    expect(updates.length, 2);
    expect(updates.first!.isOptimistic, isTrue);
    expect(updates.last!.isOptimistic, isFalse);
    expect(updates.last!.hasException, isTrue);
    expect(result.hasException, isTrue);
    // the optimistic pass must not hand its payload to either of the other
    // callbacks: onCompleted is guarded on isOptimistic, onError on hasException
    expect(completed, isNot(contains('optimisticName')));
    expect(errors.length, 1);
    expect(errors.single, isA<OperationException>());
  });

  test(
      'a throwing update leaves the optimistic transaction counter at zero and '
      'cache-driven rebroadcasts working', () async {
    final MockLink link = MockLink();
    final _CountingCache cache = _CountingCache();
    final GraphQLClient client = GraphQLClient(link: link, cache: cache);

    // The mutation writes `Single:2`, the watcher reads `Single:1`, so the
    // orphaned optimistic patch a throwing update leaves behind cannot mask
    // what the watcher is asserted to receive.
    const Map<String, dynamic> watchedData = <String, dynamic>{
      'single': {'id': '1', '__typename': 'Single', 'name': 'initialName'},
    };
    const Map<String, dynamic> writtenData = <String, dynamic>{
      'single': {'id': '1', '__typename': 'Single', 'name': 'writtenName'},
    };

    when(link.request(any)).thenAnswer((Invocation invocation) {
      final Request request = invocation.positionalArguments.first as Request;
      final OperationDefinitionNode definition = request
          .operation.document.definitions
          .whereType<OperationDefinitionNode>()
          .first;
      if (definition.type == OperationType.query) {
        return Stream.fromIterable([
          Response(data: watchedData, response: {}),
        ]);
      }
      return Stream.fromIterable([
        updateSingleResponse('networkName', id: '2'),
      ]);
    });

    final ObservableQuery<Object?> watched = client.watchQuery(
      WatchQueryOptions(
        fetchResults: true,
        document: readSingleDocument,
      ),
    );
    final List<QueryResult<Object?>?> emissions = [];
    final StreamSubscription<QueryResult<Object?>?> subscription =
        watched.stream.listen(emissions.add);
    await pumpEventQueue();

    expect(emissions.last!.data!['single']['name'], 'initialName');

    await expectLater(
      client.mutate<Object?>(
        MutationOptions<Object?>(
          document: writeSingleDocument,
          variables: {'id': '2', 'name': 'optimisticName'},
          optimisticResult:
              updateSingleResponse('optimisticName', id: '2').data,
          update: (GraphQLDataProxy cache, QueryResult<Object?>? result) =>
              throw StateError('update failed'),
        ),
      ),
      throwsStateError,
    );

    // the counter gates GraphQLCache.shouldBroadcast: a leaked increment would
    // silently stop every later cache-driven rebroadcast for this client
    expect(cache.inflightOptimisticTransactions, 0);

    client.writeQuery(readSingleRequest, data: writtenData);
    await pumpEventQueue();

    expect(emissions.last!.data!['single']['name'], 'writtenName');
    await subscription.cancel();
    await watched.close();
  });
}
