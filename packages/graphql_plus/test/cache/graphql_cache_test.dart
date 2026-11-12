import 'package:gql_exec/gql_exec.dart' show Request;
import 'package:graphql_plus/src/cache/_normalizing_data_proxy.dart';
import 'package:normalize/normalize.dart' show PartialDataException;
import 'package:test/test.dart';

import 'package:graphql_plus/graphql_plus.dart' show Operation;
import 'package:graphql_plus/src/cache/cache.dart';
import 'package:graphql_plus/src/utilities/helpers.dart' show gql;

import '../helpers.dart';
import './cache_data.dart';

typedef CacheTransaction = GraphQLDataProxy Function(GraphQLDataProxy proxy);

void main() {
  if (debuggingUnexpectedTestFailures) {
    print(
      'DEBUGGING UNEXPECTED TEST FAILURES: $debuggingUnexpectedTestFailures.\n'
      'RUNNING TESTS WITH returnPartialData SET TO TRUE.\n',
    );
  }

  group('Normalizes writes', () {
    late GraphQLCache cache;
    setUp(() {
      cache = getTestCache();
    });
    test('.writeQuery .readQuery round trip', () {
      cache.writeQuery(basicTest.request, data: basicTest.data);
      expect(
        cache.readQuery(basicTest.request),
        equals(basicTest.data),
      );
    });

    test('typeless .writeQuery .readQuery round trip', () {
      cache.writeQuery(typelessTest.request, data: typelessTest.data);
      expect(
        cache.readQuery(typelessTest.request),
        equals(typelessTest.data),
      );
    });

    test('typeless custom dataIdFromObject', () {
      cache.writeQuery(typelessTest.request, data: typelessTest.data);
      expect(
        cache.readQuery(typelessTest.request),
        equals(typelessTest.data),
      );
    });

    test('.writeQuery should fail on missing fields', () {
      expect(
        () => cache.writeQuery(basicTest.request, data: <String, dynamic>{
          ...basicTest.data,
          'a': <String, dynamic>{
            ...(basicTest.data['a'] as Map<String, dynamic>),
            'b': <String, dynamic>{
              'id': 5,
            }
          },
        }),
        throwsA(isA<PartialDataException>().having(
          (e) => e.path,
          'An accurate path to the first missing subfield',
          ['a', 'b', '__typename'],
        )),
      );
    });

    test('updating nested normalized fragment changes top level operation', () {
      cache.writeQuery(basicTest.request, data: basicTest.data);
      final idFields = {
        '__typename': updatedCValue['__typename'],
        'id': updatedCValue['id'],
      };
      cache.writeFragment(
        updatedCFragment.asRequest(
          idFields: idFields,
        ),
        data: updatedCValue,
      );

      expect(
        cache.readQuery(basicTest.request),
        equals(updatedCBasicTestData),
      );

      expect(
        cache.readFragment(
          updatedCFragment.asRequest(
            idFields: idFields,
          ),
        ),
        updatedCValue,
      );
    });

    test('updating subset query only partially overrides superset query', () {
      cache.writeQuery(basicTest.request, data: basicTest.data);

      cache.writeQuery(
        basicTestSubsetAValue.request,
        data: basicTestSubsetAValue.data,
      );
      expect(
        cache.readQuery(basicTest.request),
        equals(getUpdatedSubsetOperationData()),
      );
    });
  });

  group('Handles cyclical references', () {
    final GraphQLCache cache = getTestCache();
    test('lazily reads cyclical references', () {
      cache.writeQuery(cyclicalTest.request, data: cyclicalTest.data);
      for (final normalized in cyclicalTest.normalizedEntities!) {
        final dataId = "${normalized['__typename']}:${normalized['id']}";
        expect(cache.readNormalized(dataId), equals(normalized));
      }
    });
  });

  group('Handles Object/pointer self-references/cycles', () {
    final GraphQLCache cache = getTestCache();
    test('correctly reads cyclical references', () {
      cyclicalTest.data = cyclicalObjOperationData;
      cache.writeQuery(cyclicalTest.request, data: cyclicalTest.data);
      for (final normalized in cyclicalTest.normalizedEntities!) {
        final dataId = "${normalized['__typename']}:${normalized['id']}";
        expect(cache.readNormalized(dataId), equals(normalized));
      }
    });
  });

  group(
    '.recordOptimisticTransaction',
    () {
      late GraphQLCache cache;

      setUp(() {
        cache = getTestCache();
      });

      test(
        'OptimisticCache.readQuery and .readFragment pass through',
        () {
          cache.writeQuery(basicTest.request, data: basicTest.data);
          cache.broadcastRequested = false;
          cache.recordOptimisticTransaction(
            (proxy) {
              expect(
                proxy.readQuery(basicTest.request),
                equals(basicTest.data),
              );

              final idFields = {
                '__typename': originalCValue['__typename'],
                'id': originalCValue['id'],
              };

              expect(
                proxy.readFragment(originalCFragment.asRequest(
                  idFields: idFields,
                )),
                originalCValue,
              );

              expect(
                (proxy as NormalizingDataProxy).broadcastRequested,
                isFalse,
              );

              return proxy;
            },
            '1',
          );

          // no edits
          expect(cache.broadcastRequested, isFalse);
          expect(cache.optimisticPatches.first.id, equals('1'));
          expect(cache.optimisticPatches.first.data, equals({}));
        },
      );

      test(
        '.writeQuery, .readQuery(optimistic: true) round trip',
        () {
          cache.recordOptimisticTransaction(
            (proxy) => proxy
              ..writeQuery(
                basicTest.request,
                data: basicTest.data,
              ),
            '1',
          );
          expect(
            cache.readQuery(basicTest.request, optimistic: true),
            equals(basicTest.data),
          );
        },
      );

      test(
        'readNormalized returns correctly merged optimistic data',
        () {
          cache.recordOptimisticTransaction(
            (proxy) => proxy
              ..writeQuery(
                basicTest.request,
                data: basicTest.data,
              ),
            '1',
          );

          expect(cache.optimisticPatches.length, 1);
          expect(cache.readNormalized("C:6"),
              equals({'cField': 'value', '__typename': 'C', 'id': 6}));

          cache.writeNormalized('C:6', {
            '__typename': 'C',
            'id': 6,
            "score": null,
          });

          expect(cache.readNormalized("C:6", optimistic: false),
              equals({'__typename': 'C', 'id': 6, 'score': null}));
          expect(
              cache.readNormalized("C:6", optimistic: true),
              equals({
                '__typename': 'C',
                'id': 6,
                'cField': 'value',
                'score': null
              }));
        },
      );

      recordCFragmentUpdate(GraphQLCache cache) =>
          cache.recordOptimisticTransaction(
            (proxy) => proxy
              ..writeFragment(
                updatedCFragment.asRequest(idFields: {
                  '__typename': updatedCValue['__typename'],
                  'id': updatedCValue['id'],
                }),
                data: updatedCValue,
              ),
            '2',
          );

      test(
        'updating nested normalized fragment changes top level operation',
        () {
          cache.writeQuery(basicTest.request, data: basicTest.data);
          recordCFragmentUpdate(cache);
          expect(
            cache.readQuery(basicTest.request),
            equals(updatedCBasicTestData),
          );
        },
      );

      recordBasicSubsetData(GraphQLCache cache) =>
          cache.recordOptimisticTransaction(
            (proxy) => proxy
              ..writeQuery(
                basicTestSubsetAValue.request,
                data: basicTestSubsetAValue.data,
              ),
            '3',
          );
      test(
        'updating subset query partially overrides superset query',
        () {
          cache.writeQuery(basicTest.request, data: basicTest.data);
          recordCFragmentUpdate(cache);
          recordBasicSubsetData(cache);
          expect(
            cache.readQuery(basicTest.request, optimistic: true),
            equals(getUpdatedSubsetOperationData(withUpdatedC: true)),
          );
        },
      );

      test(
        '.removeOptimisticPatch results in data from lower layers on readQuery',
        () {
          cache.writeQuery(basicTest.request, data: basicTest.data);
          recordCFragmentUpdate(cache);
          recordBasicSubsetData(cache);
          cache.removeOptimisticPatch('2');
          cache.removeOptimisticPatch('3');
          expect(
            cache.readQuery(basicTest.request, optimistic: true),
            equals(basicTest.data),
          );
        },
      );
    },
  );

  group('Partial optimistic writes', () {
    late GraphQLCache cache;

    // Not getTestCache(): TestCache pins partialDataPolicy to `reject`, which throws
    // before the merge is reached. The partial-write path only exists under the
    // production default (`acceptForOptimisticData`), so that is what is under test.
    setUp(() {
      cache = GraphQLCache();
    });

    /// A mutation whose selection set covers `name` and `friendStatus`, used with a
    /// payload that only supplies `friendStatus` — the shape reported in #3.
    Request partialFriendStatusRequest() => Request(
          operation: Operation(
            document: gql(r'''
              mutation UpdateFriendStatus($id: ID!) {
                updateFriendStatus(id: $id) {
                  __typename
                  id
                  name
                  friendStatus
                }
              }
            '''),
          ),
          variables: {'id': '123'},
        );

    Map<String, dynamic> partialFriendStatusData() => {
          '__typename': 'Mutation',
          'updateFriendStatus': {
            '__typename': 'User',
            'id': '123',
            'friendStatus': 'SENT_PENDING',
          },
        };

    test('an omitted field keeps its cached value', () {
      cache.writeNormalized('User:123', {
        '__typename': 'User',
        'id': '123',
        'name': 'kyle',
        'friendStatus': 'NOT_FRIENDS',
      });

      cache.recordOptimisticTransaction(
        (proxy) {
          proxy.writeQuery(
            partialFriendStatusRequest(),
            data: partialFriendStatusData(),
          );
          return proxy;
        },
        '1',
      );

      expect(
        cache.readNormalized('User:123'),
        equals({
          '__typename': 'User',
          'id': '123',
          'name': 'kyle',
          'friendStatus': 'SENT_PENDING',
        }),
      );
    });

    test('an explicitly provided field still overwrites', () {
      cache.writeNormalized('User:123', {
        '__typename': 'User',
        'id': '123',
        'name': 'kyle',
        'friendStatus': 'NOT_FRIENDS',
      });

      cache.recordOptimisticTransaction(
        (proxy) {
          proxy.writeQuery(
            partialFriendStatusRequest(),
            data: partialFriendStatusData(),
          );
          return proxy;
        },
        '1',
      );

      expect(
        cache.readNormalized('User:123')!['friendStatus'],
        'SENT_PENDING',
      );
    });

    test('false and 0 are values, not omissions', () {
      cache.writeNormalized('User:123', {
        '__typename': 'User',
        'id': '123',
        'isBlocked': true,
        'loginCount': 7,
      });

      cache.recordOptimisticTransaction(
        (proxy) {
          proxy.writeQuery(
            Request(
              operation: Operation(
                document: gql(r'''
                  mutation BlockUser($id: ID!) {
                    blockUser(id: $id) {
                      __typename
                      id
                      isBlocked
                      loginCount
                    }
                  }
                '''),
              ),
              variables: {'id': '123'},
            ),
            data: {
              '__typename': 'Mutation',
              'blockUser': {
                '__typename': 'User',
                'id': '123',
                'isBlocked': false,
                'loginCount': 0,
              },
            },
          );
          return proxy;
        },
        '1',
      );

      final read = cache.readNormalized('User:123')!;
      expect(read['isBlocked'], isFalse);
      expect(read['loginCount'], 0);
    });

    test('a nested entity keeps the fields the payload omitted', () {
      cache.writeNormalized('User:123', {
        '__typename': 'User',
        'id': '123',
        'profile': {'__typename': 'Profile', 'id': 'p1'},
      });
      cache.writeNormalized('Profile:p1', {
        '__typename': 'Profile',
        'id': 'p1',
        'bio': 'hi',
      });

      cache.recordOptimisticTransaction(
        (proxy) {
          proxy.writeQuery(
            Request(
              operation: Operation(
                document: gql(r'''
                  mutation UpdateBio($id: ID!) {
                    updateProfile(id: $id) {
                      __typename
                      id
                      bio
                    }
                  }
                '''),
              ),
              variables: {'id': 'p1'},
            ),
            data: {
              '__typename': 'Mutation',
              // `bio` is selected by the mutation but omitted from the payload.
              'updateProfile': {
                '__typename': 'Profile',
                'id': 'p1',
              },
            },
          );
          return proxy;
        },
        '1',
      );

      expect(
        cache.readNormalized('Profile:p1'),
        equals({'__typename': 'Profile', 'id': 'p1', 'bio': 'hi'}),
      );
    });

    test('the base store is unchanged by the optimistic read', () {
      cache.writeNormalized('User:123', {
        '__typename': 'User',
        'id': '123',
        'name': 'kyle',
        'friendStatus': 'NOT_FRIENDS',
      });

      cache.recordOptimisticTransaction(
        (proxy) {
          proxy.writeQuery(
            partialFriendStatusRequest(),
            data: partialFriendStatusData(),
          );
          return proxy;
        },
        '1',
      );

      expect(
          cache.readNormalized('User:123', optimistic: false),
          equals({
            '__typename': 'User',
            'id': '123',
            'name': 'kyle',
            'friendStatus': 'NOT_FRIENDS',
          }));
    });
  });

  group('Handles MultipartFile variables', () {
    late GraphQLCache cache;
    setUp(() {
      cache = getTestCache();
    });
    test('.writeQuery .readQuery round trip', () {
      cache.writeQuery(fileVarsTest.request, data: fileVarsTest.data);
      expect(
        cache.readQuery(fileVarsTest.request),
        equals(fileVarsTest.data),
      );
    });
  });

  group('custom dataIdFromObject', () {
    /// Uses a `/` instead of the default `:`
    String? customDataIdFromObject(Object object) {
      if (object is Map<String, Object> &&
          object.containsKey('__typename') &&
          object.containsKey('id'))
        return "${object['__typename']}/${object['id']}";
      return null;
    }

    late GraphQLCache cache;
    setUp(() {
      cache = GraphQLCache(
        dataIdFromObject: customDataIdFromObject,
        partialDataPolicy: PartialDataCachePolicy.reject,
      );
    });

    test('.writeQuery .readQuery round trip', () {
      cache.writeQuery(basicTest.request, data: basicTest.data);
      expect(
        cache.readQuery(basicTest.request),
        equals(basicTest.data),
      );
    });

    test('typeless .writeQuery .readQuery round trip', () {
      cache.writeQuery(typelessTest.request, data: typelessTest.data);
      expect(
        cache.readQuery(typelessTest.request),
        equals(typelessTest.data),
      );
    });
  });
}
