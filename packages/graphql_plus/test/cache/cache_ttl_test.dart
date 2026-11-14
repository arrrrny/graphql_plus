import 'package:gql/language.dart' show parseString;
import 'package:gql_exec/gql_exec.dart' show Context, Request;
import 'package:graphql_plus/graphql_plus.dart' show Operation;
import 'package:graphql_plus/src/cache/cache.dart';
import 'package:test/test.dart';

Request _viewerRequest() => Request(
      operation: Operation(document: parseString(r'''
        query Viewer {
          viewer {
            __typename
            id
            name
          }
        }
      ''')),
      context: Context(),
    );

const _viewerData = <String, dynamic>{
  'viewer': {
    '__typename': 'User',
    'id': '1',
    'name': 'Ada',
  },
};

/// A cache whose clock is driven by hand, so expiry can be tested without
/// waiting for real time to pass.
class _FakeClock {
  _FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2024, 1, 1);

  DateTime now;

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

void main() {
  group('GraphQLCache TTL', () {
    test('defaultTtl expires entries once the TTL has elapsed', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(seconds: 30),
        clock: clock.call,
      );
      final request = _viewerRequest();

      cache.writeQuery(request, data: _viewerData);
      expect(cache.readQuery(request), isNotNull);

      clock.advance(const Duration(seconds: 29));
      expect(cache.readQuery(request), isNotNull);

      clock.advance(const Duration(seconds: 2));
      expect(cache.readQuery(request), isNull);
      // the expired entry is swept out of the store, not just hidden
      expect(cache.store.toMap(), isEmpty);
    });

    test('entries without a TTL never expire', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(store: InMemoryStore(), clock: clock.call);
      final request = _viewerRequest();

      cache.writeQuery(request, data: _viewerData);

      clock.advance(const Duration(days: 365));
      expect(cache.readQuery(request), isNotNull);
    });

    test('a write refreshes the expiry of an existing entry', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(seconds: 30),
        clock: clock.call,
      );
      final request = _viewerRequest();

      cache.writeQuery(request, data: _viewerData);
      clock.advance(const Duration(seconds: 20));
      cache.writeQuery(request, data: _viewerData);

      clock.advance(const Duration(seconds: 20));
      expect(cache.readQuery(request), isNotNull);

      clock.advance(const Duration(seconds: 11));
      expect(cache.readQuery(request), isNull);
    });

    test('typeTtl overrides the global default for one type', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(hours: 1),
        typeTtl: const {'User': Duration(seconds: 10)},
        clock: clock.call,
      );
      final request = _viewerRequest();

      cache.writeQuery(request, data: _viewerData);

      clock.advance(const Duration(seconds: 11));
      expect(cache.readQuery(request), isNull);
      expect(cache.store.toMap().containsKey('User:1'), isFalse);
    });

    test('setTtl overrides both typeTtl and defaultTtl for one entity', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(hours: 1),
        typeTtl: const {'User': Duration(hours: 1)},
        clock: clock.call,
      );

      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.setTtl('User:1', const Duration(seconds: 5));
      cache.writeNormalized('User:2', {'name': 'Grace'});

      clock.advance(const Duration(seconds: 6));
      expect(cache.readNormalized('User:1'), isNull);
      expect(cache.readNormalized('User:2'), isNotNull);
    });

    test('setTtl(null) drops a per-entity override', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(seconds: 10),
        clock: clock.call,
      );

      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.setTtl('User:1', const Duration(hours: 1));
      cache.setTtl('User:1', null);

      clock.advance(const Duration(seconds: 11));
      expect(cache.readNormalized('User:1'), isNull);
    });

    test('a write to an expired entity is not dropped by the sweep', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(seconds: 30),
        clock: clock.call,
      );

      cache.writeNormalized('User:1', {'name': 'Ada'});
      clock.advance(const Duration(seconds: 31));
      cache.writeNormalized('User:1', {'name': 'Grace'});

      // the expired entity is dropped before the merge, so the fresh write
      // is stored instead of being swept away right after the put
      expect(cache.store.toMap()['User:1'], {'name': 'Grace'});
      expect(cache.readNormalized('User:1'), {'name': 'Grace'});
    });

    test('a top-level read sweeps entities that nothing has read', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(seconds: 30),
        clock: clock.call,
      );

      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.writeNormalized('User:2', {'name': 'Grace'});
      clock.advance(const Duration(seconds: 31));

      // neither entity was ever read; the sweep on the next top-level read
      // is what reclaims them
      cache.readQuery(_viewerRequest());

      expect(cache.store.toMap(), isEmpty);
    });
  });

  group('GraphQLCache manual invalidation and eviction', () {
    test('evict removes a single entity', () {
      final cache = GraphQLCache(store: InMemoryStore());
      final request = _viewerRequest();

      cache.writeQuery(request, data: _viewerData);
      expect(cache.store.toMap(),
          containsPair('User:1', isA<Map<String, dynamic>>()));

      cache.evict('User:1');

      expect(cache.store.toMap().containsKey('User:1'), isFalse);
      expect(cache.readQuery(request), isNull);
    });

    test('evictAll(typeName:) only removes entities of that type', () {
      final cache = GraphQLCache(store: InMemoryStore());
      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.writeNormalized('User:2', {'name': 'Grace'});
      cache.writeNormalized('Post:1', {'title': 'Hello'});

      cache.evictAll(typeName: 'User');

      expect(cache.store.toMap().keys, unorderedEquals(['Post:1']));
    });

    test('evictAll() removes every entity', () {
      final cache = GraphQLCache(store: InMemoryStore());
      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.writeNormalized('Post:1', {'title': 'Hello'});

      cache.evictAll();

      expect(cache.store.toMap(), isEmpty);
    });

    test('invalidate drops the entity on the next read', () {
      final cache = GraphQLCache(store: InMemoryStore());
      final request = _viewerRequest();

      cache.writeQuery(request, data: _viewerData);
      cache.invalidate('User:1');
      // invalidation is lazy: the entry is still in the store until it is read
      expect(cache.store.toMap().containsKey('User:1'), isTrue);

      expect(cache.readQuery(request), isNull);
      expect(cache.store.toMap().containsKey('User:1'), isFalse);
    });

    test('clear empties the store and forgets its bookkeeping', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(seconds: 30),
        clock: clock.call,
      );

      cache.writeQuery(_viewerRequest(), data: _viewerData);
      cache.clear();

      expect(cache.store.toMap(), isEmpty);

      // the cache must not keep evicting against entries that no longer exist
      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.writeNormalized('User:2', {'name': 'Grace'});
      expect(cache.store.toMap().keys, unorderedEquals(['User:1', 'User:2']));
    });

    test('evicting an entity drops its TTL override', () {
      final clock = _FakeClock();
      final cache = GraphQLCache(
        store: InMemoryStore(),
        defaultTtl: const Duration(seconds: 30),
        clock: clock.call,
      );

      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.setTtl('User:1', const Duration(hours: 1));
      cache.evict('User:1');

      // the override belongs to the entity: the fresh write is aged by the
      // default TTL again, not by the stale per-entity override
      cache.writeNormalized('User:1', {'name': 'Grace'});
      clock.advance(const Duration(seconds: 31));
      expect(cache.readNormalized('User:1'), isNull);
    });
  });

  group('GraphQLCache size limits', () {
    test('maxEntries evicts the least recently used entry', () {
      final cache = GraphQLCache(store: InMemoryStore(), maxEntries: 2);

      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.writeNormalized('User:2', {'name': 'Grace'});
      cache.writeNormalized('User:3', {'name': 'Alan'});

      expect(cache.store.toMap().keys, unorderedEquals(['User:2', 'User:3']));
    });

    test('a read counts as a use for maxEntries eviction', () {
      final cache = GraphQLCache(store: InMemoryStore(), maxEntries: 2);

      cache.writeNormalized('User:1', {'name': 'Ada'});
      cache.writeNormalized('User:2', {'name': 'Grace'});
      expect(cache.readNormalized('User:1'), isNotNull);
      cache.writeNormalized('User:3', {'name': 'Alan'});

      expect(cache.store.toMap().keys, unorderedEquals(['User:1', 'User:3']));
    });

    test('maxSizeBytes evicts the least recently used entry', () {
      final cache = GraphQLCache(store: InMemoryStore(), maxSizeBytes: 24);

      cache.writeNormalized('User:1', {'name': 'aaaaaaaaaa'});
      cache.writeNormalized('User:2', {'name': 'bbbbbbbbbb'});

      expect(cache.store.toMap().keys, unorderedEquals(['User:2']));
    });

    test('maxSizeBytes accounts the merged entity, not the incoming fragment',
        () {
      final cache = GraphQLCache(store: InMemoryStore(), maxSizeBytes: 45);

      // typed <String, Object> so the write takes the deep-merge branch
      cache.writeNormalized('User:1', <String, Object>{'name': 'aaaaaaaaaa'});
      cache.writeNormalized('User:2', <String, Object>{'name': 'bbbbbbbbbb'});
      expect(cache.store.toMap().keys, unorderedEquals(['User:1', 'User:2']));

      // the fragment alone is 20 bytes, but merged into User:1 the stored
      // entity is 40 — the budget is enforced against the stored size
      cache.writeNormalized('User:1', <String, Object>{'age': 'cccccccccc'});

      expect(cache.store.toMap().keys, unorderedEquals(['User:1']));
    });

    test('maxSizeBytes counts UTF-8 bytes, not UTF-16 code units', () {
      final cache = GraphQLCache(store: InMemoryStore(), maxSizeBytes: 50);

      // 12 'ş' are 12 UTF-16 code units but 24 UTF-8 bytes, so the entity
      // is 35 bytes on the wire, not 21
      cache.writeNormalized('User:1', {'name': 'şşşşşşşşşşşş'});
      cache.writeNormalized('User:2', {'name': 'aaaaaaaaaa'});

      expect(cache.store.toMap().keys, unorderedEquals(['User:2']));
    });

    test('invalidate keeps the size budget honest for an untracked entry', () {
      final cache = GraphQLCache(store: InMemoryStore(), maxSizeBytes: 24);

      // a write straight to the store bypasses the cache, so the entry has no
      // bookkeeping until it is invalidated
      cache.store.put('User:9', {'name': 'zzzzzzzzzz'});
      cache.invalidate('User:9');
      expect(cache.readNormalized('User:9'), isNull);

      cache.writeNormalized('User:1', {'name': 'aaaaaaaaaa'});
      cache.writeNormalized('User:2', {'name': 'bbbbbbbbbb'});

      expect(cache.store.toMap().keys, unorderedEquals(['User:2']));
    });
  });

  group('GraphQLCache constructor validation', () {
    test('non-positive limits throw in release builds too', () {
      // validated in the constructor body, not with `assert`, so the check
      // survives AOT — a negative maxEntries would hang _enforceLimits
      expect(
        () => GraphQLCache(store: InMemoryStore(), maxEntries: 0),
        throwsArgumentError,
      );
      expect(
        () => GraphQLCache(store: InMemoryStore(), maxEntries: -1),
        throwsArgumentError,
      );
      expect(
        () => GraphQLCache(store: InMemoryStore(), maxSizeBytes: 0),
        throwsArgumentError,
      );
    });
  });
}
