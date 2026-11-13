# Bug Assessment: Partial `optimisticResult` nulls out existing cache fields

- **Slug**: optimistic-partial-nulls-cache
- **Created**: 2026-11-12
- **Source**: https://github.com/arrrrny/graphql_plus/issues/3
- **Verdict**: valid
- **Severity**: high

## Report (verbatim or summarized)

> Providing a partial object to `optimisticResult` overwrites the cached entity's fields that
> were NOT provided with `null`. Example: an optimistic write of
> `{id: 123, friendStatus: SENT_PENDING}` turns a cached user
> `{id: 123, name: kyle, friendStatus: NOT_FRIENDS}` into
> `{id: 123, name: null, friendStatus: SENT_PENDING}`.
>
> **Problem**
> - Partial optimistic writes destroy existing cache data for omitted fields
> - Deviates from Apollo's merge semantics (omitted fields should be left untouched)
> - High-priority bug upstream; causes visible UI regressions after mutations

Mirrors `zino-hofmann/graphql-flutter#1118` (upstream label: Priority: High, 10 comments).
No comments on the fork-side mirror.

## Symptom

When `MutationOptions.optimisticResult` (or a `cache.recordOptimisticTransaction` write)
supplies an object that omits a field present in the mutation's selection set, the omitted
field is written to the cache as `null` instead of being left untouched. A UI rendering the
affected entity briefly shows the field blank, then corrects itself when the network response
lands — a visible flicker and, for any consumer that persists the cache, a data-loss window.

## Reproduction

Confirmed against `graphql_plus` 5.2.6 with a failing test (kept at
`.specify/bugs/optimistic-partial-nulls-cache/repro_test.dart`):

1. Seed a normalized entity via `cache.writeNormalized('User:123', {__typename: User, id: 123,
   name: kyle, friendStatus: NOT_FRIENDS})`.
2. Record an optimistic transaction whose mutation selects `__typename id name friendStatus`
   but whose data payload supplies only `{__typename, id, friendStatus}`.
3. `cache.readNormalized('User:123')` returns
   `{__typename: User, id: 123, name: null, friendStatus: SENT_PENDING}`.

Observed patch contents (printed by the repro):

```
PATCH: {Mutation: {...}, User:123: {__typename: User, id: 123, name: null, friendStatus: SENT_PENDING}}
READ : {__typename: User, id: 123, name: null, friendStatus: SENT_PENDING}
```

Expected: `name` stays `kyle`.

## Suspected Code Paths

- `packages/graphql_plus/lib/src/cache/_optimistic_transactions.dart:88-101`
  — `OptimisticProxy.writeNormalized`. Records whatever normalize produced into the patch
  map, including nulls. The `deeplyMergeLeft([existing, value])` here merges *within the
  patch*, not against the store, so it does not protect omitted fields.
- `packages/graphql_plus/lib/src/cache/cache.dart:36` — `partialDataPolicy` defaults to
  `PartialDataCachePolicy.acceptForOptimisticData`.
- `packages/graphql_plus/lib/src/cache/_optimistic_transactions.dart:41-44` —
  `OptimisticProxy.acceptPartialData` is therefore `true`, which is what tells `normalize`
  to fill missing selected fields with `null` rather than reject.
- `packages/graphql_plus/lib/src/cache/cache.dart:110-137` — `GraphQLCache.readNormalized`
  overlays each patch with `deeplyMergeLeft([value, patchData])`; a null in `patchData` wins
  over the stored value.
- `packages/graphql_plus/lib/src/utilities/helpers.dart:47-52` — `deeplyMergeLeft` /
  `_recursivelyAddAll`: a later map's key overwrites unconditionally, including with `null`.

## Root Cause Hypothesis

`GraphQLCache` defaults `partialDataPolicy` to `acceptForOptimisticData`, which makes
`OptimisticProxy.acceptPartialData` return `true`. `normalize` then treats every selected
field missing from the optimistic payload as `null` and emits it into the normalized entity.
`OptimisticProxy.writeNormalized` records that entity verbatim into the `OptimisticPatch`, and
`GraphQLCache.readNormalized` overlays the patch onto the store with `deeplyMergeLeft`, where
a `null` overwrites the existing value. The null is therefore not a merge bug — it is
`normalize`'s partial-data fill leaking into the merge. **Confidence: high** (reproduced).

## Proposed Remediation

**Preferred**: stop nulls that originate from partial-data filling from reaching the store.

`OptimisticProxy.writeNormalized` should drop `null`-valued leaf entries before recording the
patch, so a field that the optimistic payload omitted can never clobber a stored value. This
matches the semantics the issue asks for ("fields absent from the partial object must not
overwrite existing values") and matches Apollo's observable behaviour for optimistic writes.
It is a small, local change confined to the optimistic proxy, with no public API change.

**Alternatives**:

- **Reject partial optimistic data instead** (`PartialDataCachePolicy.reject`): would surface
  a `PartialDataException` rather than a silent null. Correct-by-construction but breaking —
  every existing caller relying on partial optimistic results starts throwing. Not viable on
  `5.x` (constitution principle III).
- **Make the merge null-aware in `readNormalized`** (skip `null` patch values when the store
  has a non-null value): no new write path, but it cannot distinguish an omitted field from a
  deliberately-cleared one, and it changes read semantics for *all* patches, including
  non-optimistic ones. Broader blast radius than the preferred fix.

**Files likely to change**:

- `packages/graphql_plus/lib/src/cache/_optimistic_transactions.dart`
- `packages/graphql_plus/test/cache/graphql_cache_test.dart`

**Tests to add or update**:

- Partial optimistic write preserves a sibling field that the payload omits (the repro,
  promoted into `test/cache/graphql_cache_test.dart`).
- Same guarantee for a nested entity (a partial write to a child must not null the child's
  other fields).
- Same guarantee for `writeFragment` through the optimistic proxy.
- An explicit `null` in an optimistic payload: assert and document the chosen behaviour so the
  trade-off is visible rather than accidental.

## Risks & Considerations

- **Behaviour change for explicit nulls.** Under the preferred fix, an optimistic payload that
  deliberately sets a field to `null` no longer blanks it optimistically; it will blank when
  the network response lands. Acceptable for optimistic UI, but it must be documented in
  `CHANGELOG.md`.
- **Not an API break.** No signature, default, or export changes, so this is a `5.x`-legal fix.
- **Patch-level data loss is bounded.** The optimistic patch is transient; the base store is
  only affected through the read path, so no persisted corruption occurs unless the caller
  writes the optimistic read back to disk.
- **Test isolation.** The existing test at
  `test/cache/graphql_cache_test.dart:217-232` asserts that a *base* `writeNormalized` with
  `score: null` is visible on an optimistic read. That path is not the optimistic proxy and
  must keep passing — it is the guard against over-broadly stripping nulls.

## Open Questions

- [NEEDS CLARIFICATION: whether `friendStatus` style "sentinel" values (e.g. a field
  intentionally set to null to clear it) are used in practice by downstream consumers.] The
  preferred fix treats explicit nulls as omissions; if a consumer needs a true optimistic
  clear, a follow-up opt-in flag would be required.