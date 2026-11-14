import 'dart:convert';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:gql_exec/gql_exec.dart' show Request;
import 'package:graphql_plus/src/cache/_normalizing_data_proxy.dart';
import 'package:graphql_plus/src/cache/fragment.dart' show FragmentRequest;
import 'package:meta/meta.dart';

import 'package:graphql_plus/src/utilities/helpers.dart';
import 'package:graphql_plus/src/cache/store.dart';

import 'package:graphql_plus/src/cache/_optimistic_transactions.dart';
import 'package:normalize/normalize.dart';

export 'package:graphql_plus/src/cache/data_proxy.dart';
export 'package:graphql_plus/src/cache/store.dart';
export 'package:graphql_plus/src/cache/hive_store.dart';
export 'package:graphql_plus/src/cache/isolate_store.dart';
export 'package:graphql_plus/src/cache/fragment.dart';

typedef VariableEncoder = Object Function(Object t);

/// Optimistic GraphQL Entity cache with [normalize] [TypePolicy] support
/// and configurable [store].
///
/// **NOTE**: The default [InMemoryStore] does _not_ persist to disk.
/// The recommended store for persistent environments is the [HiveStore].
///
/// [dataIdFromObject] and [typePolicies] are passed down to [normalize] operations, which say:
/// > IDs are determined by the following:
/// >
/// > 1. If a `TypePolicy` is provided for the given type, it's `TypePolicy.keyFields` are used.
/// > 2. If a `dataIdFromObject` funciton is provided, the result is used.
/// > 3. The `id` or `_id` field (respectively) are used.
class GraphQLCache extends NormalizingDataProxy {
  GraphQLCache({
    Store? store,
    this.dataIdFromObject,
    this.typePolicies = const {},
    this.possibleTypes = const {},
    this.partialDataPolicy = PartialDataCachePolicy.acceptForOptimisticData,
    this.defaultTtl,
    this.typeTtl = const {},
    this.maxEntries,
    this.maxSizeBytes,
    DateTime Function()? clock,
    Object? Function(Object?) sanitizeVariables = sanitizeFilesForCache,
  })  : sanitizeVariables = variableSanitizer(sanitizeVariables),
        store = store ?? InMemoryStore(),
        _clock = clock ?? DateTime.now {
    // Validated in the body, not with `assert`: asserts are compiled out of
    // release builds, and a non-positive limit makes `_enforceLimits` loop
    // forever there.
    final entryLimit = maxEntries;
    if (entryLimit != null && entryLimit <= 0) {
      throw ArgumentError.value(entryLimit, 'maxEntries', 'must be positive');
    }
    final sizeLimit = maxSizeBytes;
    if (sizeLimit != null && sizeLimit <= 0) {
      throw ArgumentError.value(
        sizeLimit,
        'maxSizeBytes',
        'must be positive',
      );
    }
  }

  /// Stores the underlying normalized data. Defaults to an [InMemoryStore]
  ///
  /// **WARNING**: Directly editing the contents of the store will not automatically
  /// rebroadcast operations.
  final Store store;

  /// How long an entity stays fresh when nothing more specific applies.
  ///
  /// `null` (the default) means entities never expire on their own.
  ///
  /// See [typeTtl] for a per-type TTL and [setTtl] for a per-entity one.
  final Duration? defaultTtl;

  /// Per-type TTLs, keyed by GraphQL type name (`__typename`).
  ///
  /// An entity whose type appears here uses that TTL instead of [defaultTtl].
  /// `ROOT_QUERY` and `ROOT_MUTATION` are ordinary type names here, so a query
  /// root can be expired too.
  final Map<String, Duration> typeTtl;

  /// Maximum number of entities kept in the store.
  ///
  /// `null` (the default) means no limit. When the limit is exceeded the least
  /// recently used entities are evicted on write. Reads count as a use, so an
  /// entry that is being watched is never the one evicted.
  final int? maxEntries;

  /// Maximum approximate size, in bytes, of the entities kept in the store.
  ///
  /// `null` (the default) means no limit. Sizes are estimated from the JSON
  /// encoding of each entity, which cached GraphQL data always has. When the
  /// limit is exceeded the least recently used entities are evicted on write;
  /// an entity that is larger than the whole budget on its own is kept, since
  /// dropping it would make every write a cache miss.
  final int? maxSizeBytes;

  /// The clock used to age entries. Exposed for testing.
  final DateTime Function() _clock;

  /// TTL and size bookkeeping, keyed by normalized data id.
  ///
  /// An id absent from this map is an entity with no expiry and no size
  /// accounting - which is the state of every cache that configures neither
  /// [defaultTtl]/[typeTtl] nor [maxEntries]/[maxSizeBytes], so those caches
  /// pay nothing: [_recordWrite] records nothing, and the sweep, the touch
  /// and the limit enforcement are no-ops on an empty map.
  final Map<String, _CacheEntry> _entries = {};

  /// Per-entity TTL overrides written through [setTtl].
  final Map<String, Duration> _ttlOverrides = {};

  /// Running total of [_CacheEntry.size], for [maxSizeBytes].
  int _trackedSize = 0;

  /// Whether any TTL or size feature is configured and writes must keep
  /// [_entries] bookkeeping at all.
  bool get _tracksEntries =>
      defaultTtl != null ||
      typeTtl.isNotEmpty ||
      _ttlOverrides.isNotEmpty ||
      maxEntries != null ||
      maxSizeBytes != null;

  /// Determines how partial data should be handled when written to the cache
  ///
  /// [acceptForOptimisticData] is the default and recommended, as it provides
  /// the best balance between safety and usability.
  final PartialDataCachePolicy partialDataPolicy;

  /// Whether it is permissible to write partial data, as determined by [partialDataPolicy].
  ///
  /// Passed through to normalize. When [normalizeOperation] isn't passed [acceptPartialData],
  /// It will simply return `null` if any part of the query can't be constructed.
  @override
  bool get acceptPartialData =>
      partialDataPolicy == PartialDataCachePolicy.accept;

  /// `typePolicies` to pass down to [normalize]
  final Map<String, TypePolicy> typePolicies;

  /// `possibleTypes` to pass down to [normalize]
  final Map<String, Set<String>> possibleTypes;

  /// Optional `dataIdFromObject` function to pass through to [normalize]
  final DataIdResolver? dataIdFromObject;

  /// Input variable sanitizer for referencing custom scalar types in cache keys.
  ///
  /// Defaults to [sanitizeFilesForCache]. Can be set to `null` to disable sanitization.
  /// If present, a sanitizer will be built with [variableSanitizer]
  @override
  final SanitizeVariables sanitizeVariables;

  /// Tracks the number of ongoing transactions (cache updates)
  /// to prevent rebroadcasts until they are completed.
  ///
  /// **NOTE**: Does not track network calls
  @protected
  int inflightOptimisticTransactions = 0;

  /// Whether a cache operation has requested a broadcast and it is safe to do.
  ///
  /// The caller must [claimExectution] to clear the [broadcastRequested] flag.
  ///
  /// This is not meant to be called outside of the [QueryManager]
  bool shouldBroadcast({bool claimExecution = false}) {
    if (inflightOptimisticTransactions == 0 && broadcastRequested) {
      if (claimExecution) {
        broadcastRequested = false;
      }
      return true;
    }
    return false;
  }

  /// List of patches recorded through [recordOptimisticTransaction]
  ///
  /// They are applied in ascending order,
  /// thus data in `last` will overwrite that in `first`
  /// if there is a conflict
  @protected
  @visibleForTesting
  List<OptimisticPatch> optimisticPatches = [];

  /// Reads dereferences an entity from the first valid optimistic layer,
  /// defaulting to the base internal HashMap.
  ///
  /// Expiry is checked for the requested id only; the sweep over every entry
  /// runs once per top-level operation, in [readQuery]/[readFragment].
  Map<String, dynamic>? readNormalized(
    String rootId, {
    bool? optimistic = true,
  }) {
    if (_isExpired(_entries[rootId])) {
      _remove(rootId);
    } else {
      _touch(rootId);
    }

    var value = store.get(rootId);

    if (!optimistic!) {
      return value;
    }

    for (final patch in optimisticPatches) {
      if (patch.data.containsKey(rootId)) {
        final patchData = patch.data[rootId];
        if (value is Map<String, dynamic> &&
            patchData is Map<String, dynamic>) {
          value = deeplyMergeLeft([
            value,
            patchData,
          ]);
        } else {
          // Overwrite if not mergable
          value = patchData;
        }
      }
    }

    return value;
  }

  /// Write normalized data into the cache,
  /// deeply merging maps with existing values
  ///
  /// Called from [writeQuery] and [writeFragment].
  void writeNormalized(String dataId, Map<String, dynamic>? value) {
    // An expired entity must not survive into a fresh write: drop it before
    // the merge, so the stale value is not carried into the new one and a
    // sweep cannot delete the value this write just stored.
    if (_isExpired(_entries[dataId])) {
      _remove(dataId);
    }
    final existing = store.get(dataId);
    final stored = (value is Map<String, Object> && existing != null)
        ? deeplyMergeLeft([existing, value])
        : value;
    store.put(dataId, stored);
    _recordWrite(dataId, stored);
    _enforceLimits();
  }

  /// The per-entity expiry check in [readNormalized]/[writeNormalized] is
  /// O(1); the sweep over every entry runs here, once per top-level
  /// operation, so denormalizing a query that touches K entities does not
  /// run K full sweeps.
  @override
  Map<String, dynamic>? readQuery(Request request, {bool optimistic = true}) {
    _sweepExpired();
    return super.readQuery(request, optimistic: optimistic);
  }

  @override
  Map<String, dynamic>? readFragment(
    FragmentRequest fragmentRequest, {
    bool optimistic = true,
  }) {
    _sweepExpired();
    return super.readFragment(fragmentRequest, optimistic: optimistic);
  }

  @override
  void writeQuery(
    Request request, {
    required Map<String, dynamic> data,
    bool? broadcast = true,
  }) {
    _sweepExpired();
    super.writeQuery(request, data: data, broadcast: broadcast);
  }

  @override
  void writeFragment(
    FragmentRequest fragmentRequest, {
    required Map<String, dynamic> data,
    bool? broadcast = true,
  }) {
    _sweepExpired();
    super.writeFragment(fragmentRequest, data: data, broadcast: broadcast);
  }

  /// Manually evict the entity stored under [dataId] and request a rebroadcast.
  ///
  /// Watching queries read from the cache again on the next broadcast, so an
  /// evicted entity is refetched according to each query's [FetchPolicy].
  /// Evicting an id that is not cached is a no-op.
  void evict(String dataId) {
    if (_remove(dataId)) {
      broadcastRequested = true;
    }
  }

  /// Manually evict every entity of [typeName], or every entity when [typeName]
  /// is `null`, and request a rebroadcast.
  ///
  /// [typeName] is matched against the type part of a normalized data id, so
  /// `User` matches `User:1` and `User:{"id":1}` but not `UserProfile:1`.
  void evictAll({String? typeName}) {
    final ids = store
        .toMap()
        .keys
        .where((id) => typeName == null || _typeNameOf(id) == typeName)
        .toList();
    for (final id in ids) {
      _remove(id);
    }
    if (ids.isNotEmpty) {
      broadcastRequested = true;
    }
  }

  /// Mark [dataId] invalid so that the next read drops it from the cache.
  ///
  /// Unlike [evict], the entity is left in the store until something reads it,
  /// so invalidating a large number of entities costs nothing up front. An
  /// expired entity is swept on the read that finds it.
  void invalidate(String dataId) {
    final value = store.get(dataId);
    final existing = _entries[dataId];
    if (value == null && existing == null) {
      return;
    }
    final now = _clock();
    final size = existing?.size ??
        (maxSizeBytes == null ? 0 : _estimateSize(value ?? const {}));
    if (existing == null) {
      _trackedSize += size;
    }
    _entries[dataId] = _CacheEntry(
      expiresAt: now,
      touchedAt: existing?.touchedAt ?? now,
      size: size,
    );
    broadcastRequested = true;
  }

  /// Override the TTL of a single entity, ignoring [defaultTtl] and [typeTtl].
  ///
  /// A `null` [ttl] removes the override. Re-arming the TTL of an entity that
  /// is already cached restarts its expiry from now; a non-positive [ttl]
  /// expires it immediately.
  void setTtl(String dataId, Duration? ttl) {
    if (ttl == null) {
      _ttlOverrides.remove(dataId);
    } else {
      _ttlOverrides[dataId] = ttl;
    }
    final entry = _entries[dataId];
    if (entry == null) {
      return;
    }
    final now = _clock();
    final next = _ttlFor(dataId);
    entry.expiresAt = next == null ? null : now.add(next);
  }

  /// Remove every entity from the store and forget all TTL and size bookkeeping.
  ///
  /// Use this instead of [store]'s own `reset()`, which leaves the bookkeeping
  /// behind and makes the next writes evict against entries that no longer
  /// exist.
  void clear() {
    store.reset();
    _entries.clear();
    _ttlOverrides.clear();
    _trackedSize = 0;
    broadcastRequested = true;
  }

  /// The TTL that applies to [dataId], or `null` when it never expires.
  Duration? _ttlFor(String dataId) {
    final override = _ttlOverrides[dataId];
    if (override != null) {
      return override;
    }
    return typeTtl[_typeNameOf(dataId)] ?? defaultTtl;
  }

  /// The type part of a normalized data id, which is everything before the
  /// first `:`. A data id with no separator is its own type, so `ROOT_QUERY`
  /// can be matched by name.
  static String _typeNameOf(String dataId) {
    final separator = dataId.indexOf(':');
    return separator < 0 ? dataId : dataId.substring(0, separator);
  }

  bool _isExpired(_CacheEntry? entry) {
    final expiresAt = entry?.expiresAt;
    return expiresAt != null && !expiresAt.isAfter(_clock());
  }

  /// Drop every entity whose TTL has elapsed.
  ///
  /// This is what makes expiry a GC rather than a per-read check: an entity
  /// that nothing reads is still reclaimed as soon as the cache is touched.
  void _sweepExpired() {
    if (_entries.isEmpty) {
      return;
    }
    final now = _clock();
    final expired = _entries.entries
        .where((entry) => _isExpiredAt(entry.value, now))
        .map((entry) => entry.key)
        .toList();
    for (final id in expired) {
      _remove(id);
    }
  }

  bool _isExpiredAt(_CacheEntry entry, DateTime now) {
    final expiresAt = entry.expiresAt;
    return expiresAt != null && !expiresAt.isAfter(now);
  }

  void _touch(String dataId) {
    final entry = _entries[dataId];
    if (entry != null) {
      entry.touchedAt = _clock();
    }
  }

  /// Record the write of [value] under [dataId], replacing any earlier
  /// bookkeeping for it.
  void _recordWrite(String dataId, Map<String, dynamic>? value) {
    if (!_tracksEntries) {
      // No TTL and no size limit is configured: keep [_entries] empty so the
      // cache pays nothing for its bookkeeping (see the [_entries] docs).
      return;
    }
    final previous = _entries.remove(dataId);
    if (previous != null) {
      _trackedSize -= previous.size;
    }
    if (value == null) {
      // A null write is a delete, so the entity no longer has a size or a TTL.
      return;
    }
    final ttl = _ttlFor(dataId);
    final now = _clock();
    final size = maxSizeBytes == null ? 0 : _estimateSize(value);
    _entries[dataId] = _CacheEntry(
      expiresAt: ttl == null ? null : now.add(ttl),
      touchedAt: now,
      size: size,
    );
    _trackedSize += size;
  }

  /// Evict the least recently used entities until the configured limits hold.
  void _enforceLimits() {
    final entryLimit = maxEntries;
    if (entryLimit != null) {
      while (_entries.length > entryLimit) {
        _evictLeastRecentlyUsed();
      }
    }
    final sizeLimit = maxSizeBytes;
    if (sizeLimit != null) {
      while (_trackedSize > sizeLimit && _entries.length > 1) {
        _evictLeastRecentlyUsed();
      }
    }
  }

  void _evictLeastRecentlyUsed() {
    String? oldest;
    for (final entry in _entries.entries) {
      final current = oldest;
      if (current == null ||
          entry.value.touchedAt.isBefore(_entries[current]!.touchedAt)) {
        oldest = entry.key;
      }
    }
    if (oldest != null) {
      _remove(oldest);
    }
  }

  /// Remove [dataId] from the store and from the bookkeeping.
  ///
  /// Returns whether anything was actually there.
  bool _remove(String dataId) {
    final entry = _entries.remove(dataId);
    if (entry != null) {
      _trackedSize -= entry.size;
    }
    // The override belongs to the entity: once it is gone (evicted, expired,
    // removed), a stale override would leak here forever and silently apply
    // to a future entity written under the same id.
    _ttlOverrides.remove(dataId);
    final existed = store.get(dataId) != null || entry != null;
    store.delete(dataId);
    return existed;
  }

  /// Approximate the size of [value] in bytes for [maxSizeBytes].
  ///
  /// Cached GraphQL data is JSON, so the length of its encoding is a close
  /// estimate. A value that cannot be encoded (a custom scalar written by hand)
  /// is accounted as taking no space rather than failing the write.
  static int _estimateSize(Map<String, dynamic> value) {
    try {
      // UTF-8 bytes, not UTF-16 code units: for non-ASCII data (accents,
      // emoji) the byte length is what the memory budget actually bounds.
      return utf8.encode(jsonEncode(value)).length;
    } on Object {
      return 0;
    }
  }

  String? _parentPatchId(String id) {
    final List<String> parts = id.split('.');
    if (parts.length > 1) {
      return parts.first;
    }
    return null;
  }

  bool _patchExistsFor(String id) =>
      optimisticPatches.firstWhereOrNull(
        (patch) => patch.id == id,
      ) !=
      null;

  /// avoid race conditions from slow updates
  ///
  /// if a server result is returned before an optimistic update is finished,
  /// that update is discarded
  bool _safeToAdd(String id) {
    final String? parentId = _parentPatchId(id);
    return parentId == null || _patchExistsFor(parentId);
  }

  // TODO does patch hierachy still makes sense
  /// Record the given [transaction] into a patch with the id [addId]
  ///
  /// 1 level of hierarchical optimism is supported:
  /// * if a patch has the id `$queryId.child`, it will be removed with `$queryId`
  /// * if the update somehow fails to complete before the root response is removed,
  ///   It will still be called, but the result will not be added.
  ///
  /// This allows for multiple optimistic treatments of a query,
  /// without having to tightly couple optimistic changes
  void recordOptimisticTransaction(
    CacheTransaction transaction,
    String addId,
  ) {
    inflightOptimisticTransactions += 1;
    // The transaction callback runs user code (`MutationOptions.update`), so any
    // throw from it must not skip the decrement: the counter gates
    // [shouldBroadcast], and a leaked count disables cache broadcasts for the
    // whole client.
    try {
      final _proxy = transaction(OptimisticProxy(this)) as OptimisticProxy;
      if (_safeToAdd(addId)) {
        optimisticPatches.add(_proxy.asPatch(addId));
        broadcastRequested = broadcastRequested || _proxy.broadcastRequested;
      }
    } finally {
      inflightOptimisticTransactions -= 1;
    }
  }

  /// Remove a given patch from the list
  ///
  /// This will also remove all "nested" patches, such as `$queryId.update`
  /// (see [recordOptimisticTransaction])
  ///
  /// This allows for hierarchical optimism that is automatically cleaned up
  /// without having to tightly couple optimistic changes
  ///
  /// This is called on every network result as cleanup
  void removeOptimisticPatch(String removeId) {
    final patchesToRemove = optimisticPatches
        .where(
          (patch) =>
              patch.id == removeId || _parentPatchId(patch.id) == removeId,
        )
        .toList();

    if (patchesToRemove.isEmpty) {
      return;
    }
    // Only remove + mark broadcast requested if something was actually removed.
    // This is to prevent unnecessary rebroadcasts
    optimisticPatches.removeWhere(
      (patch) => patchesToRemove.contains(patch),
    );
    broadcastRequested = true;
  }
}

/// Bookkeeping for one cached entity: when it expires, when it was last used,
/// and how much of the [GraphQLCache.maxSizeBytes] budget it accounts for.
class _CacheEntry {
  _CacheEntry({
    required this.expiresAt,
    required this.touchedAt,
    required this.size,
  });

  /// When the entity expires, or `null` when it never does.
  DateTime? expiresAt;

  /// When the entity was last written or read, for least-recently-used eviction.
  DateTime touchedAt;

  /// The entity's approximate size in bytes, or `0` when [GraphQLCache.maxSizeBytes]
  /// is not configured.
  int size;
}

/// Determines how partial data should be handled when written to the cache
///
/// [acceptForOptimisticData] is the default and recommended, as it provides
/// the best balance between safety and usability.
enum PartialDataCachePolicy {
  /// Accept partial data in all cases (default).
  accept,

  /// Accept partial data, but only for transient optimistic writes made with
  /// [GraphQLCache.recordOptimisticTransaction]
  acceptForOptimisticData,

  /// Reject partial data in all cases.
  reject,
}
