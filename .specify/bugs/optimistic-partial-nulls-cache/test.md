# Bug Verification: Partial `optimisticResult` nulls out existing cache fields

- **Slug**: optimistic-partial-nulls-cache
- **Tested**: 2026-11-13
- **Assessment**: ./assessment.md
- **Fix**: ./fix.md
- **Result**: verified

## Summary

The original reproduction fails on the pre-fix code and passes on the fixed code, exercised
end to end rather than inferred from the unit tests. The new regression tests pass, the cache
suite is green, and the analyzer is clean. Two full-suite failures remain, both pre-existing
load-sensitive flakes that do not touch the changed code path (evidence below).

## Checks Performed

| Check | Command / Action | Result | Notes |
|-------|------------------|--------|-------|
| Reproduction (pre-fix, for the record) | `dart test test/zz_repro_optimistic_partial_test.dart` on `4eee571`-era code | fail | `PATCH: {... name: null ...}` → `READ: {name: null}`; `Expected: 'kyle' Actual: <null>` |
| Reproduction (post-fix) | same test against this branch | pass | see excerpt below |
| New / updated tests | `dart test test/cache/graphql_cache_test.dart` | pass | 22/22, including the 5 new `Partial optimistic writes` cases |
| Regression suite | `dart test` | fail (2) | 126 pass / 2 fail — pre-existing flakes, see Residual Risks |
| Lint / type-check | `dart analyze --fatal-infos` | pass | `No issues found!` |
| Formatting | `dart format --set-exit-if-changed .` | pass | 61 files, 0 changed |

## Output Excerpts

Post-fix reproduction (the decisive check):

```
PATCH: {Mutation: {updateFriendStatus({"id":"123"}): {$ref: User:123}}, User:123: {__typename: User, id: 123, friendStatus: SENT_PENDING}}
READ : {__typename: User, id: 123, name: kyle, friendStatus: SENT_PENDING}
00:02 +1: All tests passed!
```

Note the patch no longer contains a `name` key at all — the null is never recorded, so there is
nothing for the merge to overwrite with. Pre-fix the same test printed
`User:123: {__typename: User, id: 123, name: null, friendStatus: SENT_PENDING}` and failed.

Cache suite:

```
00:04 +16: Partial optimistic writes false and 0 are values, not omissions
00:04 +17: Partial optimistic writes a nested entity keeps the fields the payload omitted
00:04 +18: Partial optimistic writes the base store is unchanged by the optimistic read
00:05 +22: All tests passed!
```

## Residual Risks

- **Two full-suite failures, unrelated.** `observable_query_test.dart`
  (*can start poller*, *can deduplicate startPolling calls with different durations*) and,
  depending on the run, a `cancellable_http_link_test.dart` case. Established as pre-existing
  by: (a) neither file references `optimistic`/`recordOptimisticTransaction` — 0 matches each —
  and the only changed code is `OptimisticProxy.writeNormalized`, reachable only via an
  optimistic transaction; (b) each poller test carries a hard `timeout:
  Timeout(Duration(seconds: 1))` and fails under load; (c) `git stash` of the two changed files
  and re-running *can start poller* on unmodified code still fails; (d) the failing set varies
  between consecutive runs, which is a flake signature, while the cache suite is deterministic.
- **Deliberate-null semantics changed.** A field explicitly set to `null` in an optimistic
  payload is now treated as an omission and no longer blanks optimistically. This is the
  documented trade-off from the assessment's Risks section and is recorded in
  `packages/graphql_plus/CHANGELOG.md` under Unreleased.
- **The merge path was dead before this change.** Any caller who depended on the previous
  raw-storage behaviour (e.g. an optimistic write replacing rather than merging a nested map)
  will now see a merge. No test asserted the old behaviour, and merging is what the method's own
  documentation claimed, but this is the widest behavioural surface of the change.

## Recommendation

Close the bug — the reported symptom no longer reproduces, the regression test pins it, and no
check implicates the change. The two full-suite failures should be triaged separately as flaky
tests (they are a CI reliability problem, not a defect in this fix).