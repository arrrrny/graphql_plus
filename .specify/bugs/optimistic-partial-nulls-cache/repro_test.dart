// TEMPORARY reproduction for .specify/bugs/optimistic-partial-nulls-cache
// Run: dart test test/zz_repro_optimistic_partial_test.dart
import 'package:graphql_plus/graphql_plus.dart';
import 'package:test/test.dart';

void main() {
  test('partial optimisticResult preserves fields omitted from the payload', () {
    final cache = GraphQLCache();

    // A previous query populated this entity.
    cache.writeNormalized('User:123', {
      '__typename': 'User',
      'id': '123',
      'name': 'kyle',
      'friendStatus': 'NOT_FRIENDS',
    });

    // The mutation selects name + friendStatus, but the optimistic payload only
    // supplies friendStatus (a partial object, as the issue describes).
    const mutation = r'''
      mutation UpdateFriendStatus($id: ID!) {
        updateFriendStatus(id: $id) {
          __typename
          id
          name
          friendStatus
        }
      }
    ''';

    cache.recordOptimisticTransaction(
      (proxy) {
        proxy.writeQuery(
          Request(
            operation: Operation(document: gql(mutation)),
            variables: {'id': '123'},
          ),
          data: {
            'updateFriendStatus': {
              '__typename': 'User',
              'id': '123',
              'friendStatus': 'SENT_PENDING',
            },
          },
        );
        return proxy;
      },
      'optimistic-1',
    );

    final read = cache.readNormalized('User:123');
    // ignore: avoid_print
    print('PATCH: ${cache.optimisticPatches.single.data}');
    // ignore: avoid_print
    print('READ : $read');

    expect(read!['friendStatus'], 'SENT_PENDING');
    expect(read['name'], 'kyle',
        reason: 'omitted field must not be nulled by a partial optimistic write');
  });
}