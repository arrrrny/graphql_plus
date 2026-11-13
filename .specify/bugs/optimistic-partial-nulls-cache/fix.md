# Bug Fix: Partial `optimisticResult` nulls out existing cache fields

- **Slug**: optimistic-partial-nulls-cache
- **Fixed**: 2026-11-13
- **Assessment**: ./assessment.md
- **Status**: applied

## Summary

`OptimisticProxy.writeNormalized` now drops `null`-valued entries before recording an
optimistic patch, so a field that a partial payload omitted can no longer overwrite the value
already in the store. Doing so uncovered that the method's existing merge branch was
unreachable: its `value is Map<String, Object>` guard is always false for the
`Map<String, dynamic>` that `normalize` actually passes, so every optimistic write had been
stored raw and unmerged.

## Changes

| File | Change | Notes |
|------|--------|-------|
| `packages/graphql_plus/lib/src/cache/_optimistic_transactions.dart` | modified | `writeNormalized` strips nulls recursively via a new `_withoutNulls` helper; the dead `is Map<String, Object>` guard removed so the merge path actually runs |
| `packages/graphql_plus/test/cache/graphql_cache_test.dart` | added tests | new `Partial optimistic writes` group (5 tests); added the imports it needs |

## Diff Highlights

```dart
// before — the guard is never true for Map<String, dynamic>, so this stored raw values
if (value is Map<String, Object>) {
  final existing = data[dataId];
  data[dataId] = existing != null ? deeplyMergeLeft([existing, value]) : value;
} else {
  data[dataId] = value;
}

// after
final patch = _withoutNulls(value);
final existing = data[dataId];
data[dataId] = existing != null ? deeplyMergeLeft([existing, patch]) : patch;
```

```dart
static Map<String, dynamic> _withoutNulls(Map<String, dynamic> value) {
  final result = <String, dynamic>{};
  value.forEach((key, entry) {
    if (entry == null) return;
    result[key] = entry is Map<String, dynamic> ? _withoutNulls(entry) : entry;
  });
  return result;
}
```

## Tests Added or Updated

- `test/cache/graphql_cache_test.dart` → `Partial optimistic writes`:
  - *an omitted field keeps its cached value* — the issue's exact scenario: a mutation
    selecting `name`/`friendStatus` with a payload supplying only `friendStatus` must not
    blank `name`. This is the regression test for #3.
  - *an explicitly provided field still overwrites* — guards against over-stripping.
  - *false and 0 are values, not omissions* — `_withoutNulls` must not treat falsy scalars as
    missing.
  - *a nested entity keeps the fields the payload omitted* — same guarantee one level down.
  - *the base store is unchanged by the optimistic read* — the optimistic patch must not leak
    into `optimistic: false` reads.

All five go through `writeQuery` (the real user path), not by calling the protected
`writeNormalized` directly.

## Local Verification

- `dart analyze --fatal-infos` → **No issues found!**
- `dart format --set-exit-if-changed .` → clean (61 files, 0 changed)
- `dart test test/cache/graphql_cache_test.dart` → **22/22 pass**
- `dart test` (full client suite) → **126 pass, 2 fail**

The 2 failures are pre-existing and unrelated:
`observable_query_test.dart` (*can start poller* / *can deduplicate startPolling calls with
different durations*) and, run-to-run, a `cancellable_http_link_test.dart` case.

Evidence they are not caused by this change:
1. Neither file references `optimistic` or `recordOptimisticTransaction` (0 matches each), and
   the only code changed is `OptimisticProxy.writeNormalized`, reachable solely through an
   optimistic transaction.
2. Those tests carry `timeout: Timeout(Duration(seconds: 1))` each — they fail under load.
3. Reverting the two changed files with `git stash` and re-running *can start poller* on
   unmodified code **still fails**, so the failure predates this branch.
4. The failing set differs between consecutive runs (a flake signature), while the cache suite
   is deterministic at 22/22.

The pre-fix behaviour was captured first, in `.specify/bugs/optimistic-partial-nulls-cache/repro_test.dart`:
patch `User:123: {__typename: User, id: 123, name: null, friendStatus: SENT_PENDING}`, read
back `name: null`.

## Deviations from Assessment

- The assessment predicted the fix would be a null-stripping pass inside the existing
  `if (value is Map<String, Object>)` branch. In practice that branch **never executed**, so
  the stripping alone would have had no effect. The guard had to be removed as part of the fix.
  This is a widening of the assessment's scope, recorded here rather than by editing
  `assessment.md`.
- The assessment listed two tests; five were written, covering explicit-value preservation,
  nesting, and store isolation as well as the reported case.

## Follow-ups

- `CHANGELOG.md`: record that a deliberately-null optimistic field is now treated as an
  omission (the documented trade-off from the assessment's "Risks").
- The dead-guard discovery is a second instance of the pattern recorded as DF-06 in
  `specs/001-5x-hardening/DESIGN_FAILURES.md` (normalization semantics leaking through an
  untested branch) and is worth citing there.
- Open question from the assessment stands: if a consumer needs a true optimistic *clear*, that
  needs an opt-in flag, not a silent behaviour.