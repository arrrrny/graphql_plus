# Tasks: 6.x — clean-architecture rewrite

**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

All tasks are `[ ]` — this spec is the plan, not the work. Order is the dependency order from
the plan's phase table. Nothing here may start before Phase 0 is green.

## Phase 0 — Guardrails before code (blocks everything)

- [ ] T001 Create the `test/conformance` package skeleton with the corpus format
- [ ] T002 Populate the corpus from `packages/graphql_plus/test` and the mirrored issue reports
- [ ] T003 Implement the 5.x runner and get the corpus green against `graphql_plus` 5.2.6
- [ ] T004 Add the import-boundary check (fails if `lib/src/domain/**` imports `package:flutter/`,
  `package:http/`, `package:gql_*`, `package:hive_ce/`, or `dart:io`)
- [ ] T005 Prove the boundary check works by committing a deliberate violation and watching CI fail
- [ ] T006 Add the golden public-API file and the check that fails when `graphql_plus.dart` changes

## Phase 1 — Domain skeleton (US1)

- [ ] T007 [P] `Operation`, `OperationType`, `OperationVariables` value objects + tests
- [ ] T008 [P] `CacheEntity` (id, type, field map, expiry) + tests
- [ ] T009 [P] `CacheRepository` contract + in-memory fake used by all later tests
- [ ] T010 [P] `Transport` contract + `ConnectionState` enum + recording fake
- [ ] T011 Wire the four contracts into a `zfa`-generated skeleton; verify no domain import escapes

## Phase 2 — Result and failure model (US4)

- [ ] T012 [P] Sealed `OperationFailure` hierarchy + tests for cause/stack retention
- [ ] T013 `OperationResult` as success-or-failure; delete the nullable-payload path
- [ ] T014 [P] Test: a response arriving after a timeout produces exactly one terminal event
- [ ] T015 [P] Test: cancellation produces `CancelledFailure` with its reason
- [ ] T016 [P] Test: a late response after settle is dropped and logged once, never re-completed
- [ ] T017 Remove `gqlDeepEquals` / `gqlAsyncDeepEquals` statics; equality is per-client (DF-03)

## Phase 3 — Cache contract and merge policy (US3)

- [ ] T018 `MergePolicy` in `domain/cache`: absent field ≠ instruction
- [ ] T019 [P] Property test: merge then read returns the union of provided and cached fields
- [ ] T020 [P] Test: partial optimistic write preserves omitted fields (closes 5.x issue #3)
- [ ] T021 `TtlPolicy` + `EvictionPolicy` value objects and the `entriesFor(type)` contract
- [ ] T022 [P] Test: TTL expiry triggers refetch per `FetchPolicy`
- [ ] T023 [P] Test: size limit evicts oldest and exposes the eviction
- [ ] T024 [P] Test: explicit invalidation of an entity and of a type

## Phase 4 — HTTP and WebSocket transports (US2)

- [ ] T025 `HttpTransport` on `package:http` + conformance subset green
- [ ] T026 `WebSocketTransport` with a `ConnectionState` stream (closes DF-10, 5.x issue #6)
- [ ] T027 [P] Test: subscription connect handshake against a provider that rejects `content-length: 0`
- [ ] T028 Full conformance suite green against 6.x; divergences enumerated
- [ ] T029 Write `MIGRATION-6x.md` from the divergence list

## Phase 5 — Dio and AppSync transports (US5)

- [ ] T030 `DioTransport` with interceptor, timeout, and cookie support (6.x issue #13, #7)
- [ ] T031 [P] Test: dio interceptors observe and mutate GraphQL requests
- [ ] T032 `AppSyncTransport` REALTIME serializer + per-message authorization (6.x issue #16)
- [ ] T033 [P] Test: AppSync handshake and subscribe envelopes against a recorded fixture
- [ ] T034 Per-transport conformance runs in CI

## Phase 6 — Widgets on injected interfaces (US2 / DF-12)

- [ ] T035 Port `GraphQLProvider` to accept an injected client; delete client construction from widgets
- [ ] T036 Port `Query`, `Mutation`, `Subscription` widgets to the new result type
- [ ] T037 Port `useQuery` / `useMutation` / `useSubscription` hooks
- [ ] T038 Widget test suite passes with unchanged test intent
- [ ] T039 Update both READMEs and the pub.dev description for 6.x

## Phase 7 — Offline queue (US6)

- [ ] T040 `MutationQueueEntry` (operation, idempotency key, attempts, next-attempt) + tests
- [ ] T041 `PersistedMutationQueue` with ordering and exactly-once replay
- [ ] T042 [P] Test: three mutations while disconnected replay once, in order, on reconnect
- [ ] T043 [P] Test: a replayed mutation that fails is retried per policy, not infinitely

## Phase 8 — Isolate-backed cache (US6)

- [ ] T044 `IsolateCacheWorker` implementing the `CacheRepository` contract
- [ ] T045 [P] Benchmark: 10,000-entity persist does not exceed the UI-frame budget
- [ ] T046 Decide, from the benchmark, whether the isolate path becomes the default

## Cross-cutting

- [ ] T047 Every phase re-runs the boundary check, the golden API check, and the conformance suite
- [ ] T048 Coverage gates: `domain` ≥ 95%, `lib/` ≥ 85%
- [ ] T049 Resolve or explicitly accept each DF-01…DF-13 finding in the 6.x release notes
- [ ] T050 Close or follow-up each `6.x`-labelled issue with a link to the closing requirement