import 'package:graphql_plus/graphql_plus.dart';
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import './helpers.dart';

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

  final DocumentNode writeSingleDocument = parseString(writeSingle);

  Response updateSingleResponse(String name) => Response(
        data: <String, dynamic>{
          'updateSingle': {
            'id': '1',
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

    final QueryResult<Object?> result = await client.mutate<Object?>(
      MutationOptions<Object?>(
        document: writeSingleDocument,
        variables: {'id': '1', 'name': 'optimisticName'},
        optimisticResult: updateSingleResponse('optimisticName').data,
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
    final QueryResult<Object?> result = await client.mutate<Object?>(
      MutationOptions<Object?>(
        document: writeSingleDocument,
        variables: {'id': '1', 'name': 'optimisticName'},
        optimisticResult: updateSingleResponse('optimisticName').data,
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
  });
}
