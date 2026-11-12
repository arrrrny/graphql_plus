/// Optimistic proxying and patching classes and typedefs used by `./cache.dart`
import 'dart:collection';

import 'package:graphql_plus/src/utilities/helpers.dart';
import 'package:meta/meta.dart';

import 'package:graphql_plus/src/cache/_normalizing_data_proxy.dart';
import 'package:graphql_plus/src/cache/data_proxy.dart';

import 'package:graphql_plus/src/cache/cache.dart'
    show GraphQLCache, PartialDataCachePolicy;
import 'package:normalize/policies.dart';

/// API for users to provide cache updates through
typedef CacheTransaction = GraphQLDataProxy Function(GraphQLDataProxy proxy);

/// An optimistic update recorded with [GraphQLCache.recordOptimisticTransaction],
/// identifiable through it's [id].
@immutable
class OptimisticPatch {
  const OptimisticPatch(this.id, this.data);
  final String id;
  final HashMap<String, Map<String, dynamic>?> data;
}

/// Proxy by which users record [_OptimisticPatch]s though
/// [GraphQLCache.recordOptimisticTransaction].
///
/// Implements, and is exposed as, a [GraphQLDataProxy].
/// It's `optimistic` parameters default to `true`,
/// but the user can override them to read directly from the `store`.
class OptimisticProxy extends NormalizingDataProxy {
  OptimisticProxy(this.cache);

  GraphQLCache cache;

  /// Whether it is permissible to write partial data, as determined by [partialDataPolicy].
  ///
  /// Passed through to normalize. When [normalizeOperation] isn't passed [acceptPartialData],
  /// It will set missing fields to `null` if any part of a structurally valid query result is missing.
  @override
  bool get acceptPartialData =>
      cache.partialDataPolicy != PartialDataCachePolicy.reject;

  /// `typePolicies` to pass down to `normalize` (proxied from [cache])
  Map<String, TypePolicy> get typePolicies => cache.typePolicies;

  /// `possibleTypeOf` to pass down to `normalize` (proxied from [cache])
  Map<String, Set<String>> get possibleTypes => cache.possibleTypes;

  /// Optional `dataIdFromObject` function to pass through to [normalize]
  /// (proxied from [cache])
  DataIdResolver? get dataIdFromObject => cache.dataIdFromObject;

  @override
  SanitizeVariables get sanitizeVariables => cache.sanitizeVariables;

  HashMap<String, Map<String, dynamic>?> data = HashMap();

  @override
  Map<String, dynamic>? readNormalized(String rootId,
      {bool optimistic = true}) {
    if (!optimistic) {
      return cache.readNormalized(rootId, optimistic: false);
    }
    // the cache calls `patch.data.containsKey(rootId)`,
    // so this is not an infinite loop
    return data[rootId] ?? cache.readNormalized(rootId, optimistic: true);
  }

  // TODO consider using store for optimistic patches
  /// Write normalized data into the patch,
  /// deeply merging maps with existing values
  ///
  /// Called from [writeQuery] and [writeFragment].
  @override
  void writeNormalized(String dataId, Map<String, dynamic>? value) {
    if (value == null) {
      data[dataId] = null;
      return;
    }
    // `normalize` emits an explicit `null` for every selected field that a partial
    // optimistic payload omitted (see [acceptPartialData]). Recording those nulls
    // lets an omitted field overwrite the value already in the store when the patch
    // is merged in `GraphQLCache.readNormalized`, which blanks fields the caller
    // never mentioned. Dropping them makes an absent field a no-op rather than a
    // clear, which is the documented optimistic-merge semantic.
    //
    // Only strip when there is something to protect. For an entity the store has
    // never seen, the stripped keys are exactly what keeps it denormalizable: a
    // selected field missing from the normalized data raises `PartialDataException`
    // in `denormalize_node`, which `denormalize_operation` turns into `null`. An
    // optimistic *create* would then read back as nothing at all.
    final hasSomethingToProtect = data.containsKey(dataId) ||
        cache.readNormalized(dataId, optimistic: false) != null;
    final patch = hasSomethingToProtect ? _withoutNulls(value) : value;
    final existing = data[dataId];
    data[dataId] =
        existing != null ? deeplyMergeLeft([existing, patch]) : patch;
  }

  /// Returns a copy of [value] with every `null`-valued entry removed, recursively.
  ///
  /// Only `null` leaves are dropped; `false`, `0` and `''` are real values and are kept.
  /// A map whose entries are all null collapses to an empty map, which merges as a no-op.
  static Map<String, dynamic> _withoutNulls(Map<String, dynamic> value) {
    final result = <String, dynamic>{};
    value.forEach((key, entry) {
      if (entry == null) {
        return;
      }
      result[key] =
          entry is Map<String, dynamic> ? _withoutNulls(entry) : entry;
    });
    return result;
  }

  OptimisticPatch asPatch(String id) => OptimisticPatch(id, data);
}
