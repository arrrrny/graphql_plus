# Feature Specification: 6.x — clean-architecture rewrite of the GraphQL client

**Feature Branch**: `002-6x-rewrite`

**Created**: 2026-11-12

**Status**: Draft

**Input**: The design failures catalogued in
[`../001-5x-hardening/DESIGN_FAILURES.md`](../001-5x-hardening/DESIGN_FAILURES.md), plus the
seven `6.x`-labelled transferred upstream issues. Target: a from-scratch client that satisfies
the same feature set, on a clean architecture, generated and structured with the Zuraffa (`zfa`)
framework, under the project's TDD constitution.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A domain layer that knows nothing about HTTP (Priority: P1)

A developer reading `packages/graphql_plus/lib/domain` finds entities, value objects, and
use-case contracts. It imports no Flutter, no `http`, no `gql_*`, no `hive_ce`. The same
domain code can be compiled for a CLI or a server.

**Why this priority**: it is the foundation every other story is built on, and it is the
single thing that makes DF-01, DF-03, DF-06 and DF-09 impossible to reintroduce. If the
domain layer is correct, the rest can be replaced incrementally without touching callers.

**Independent Test**: a CI import-boundary check fails the build if any file under `domain/`
imports a transport, storage, or Flutter package. The domain test suite runs under plain
`dart test` with no Flutter binding.

**Acceptance Scenarios**:

1. **Given** the repository, **When** the import-boundary check runs, **Then** no file under
   `domain/` imports `package:flutter/`, `package:http/`, `package:gql_`, or `package:hive_ce`.
2. **Given** a new use case, **When** it is written, **Then** it compiles and tests against
   in-memory fakes of the repository contracts only.

---

### User Story 2 - Behavior parity with 5.x, proven by a conformance suite (Priority: P1)

A user upgrading from `graphql_plus` 5.x gets the same results, the same cache semantics, and
the same error surface. Nothing silently changes.

**Why this priority**: a rewrite with no parity proof is a rewrite nobody can adopt. This
story is the gate for the 6.0.0 release.

**Independent Test**: a shared conformance suite (operation documents, fixtures, expected
results) is run against both the 5.x client and the 6.x client; every case must produce
identical normalized cache state and identical exceptions.

**Acceptance Scenarios**:

1. **Given** the conformance corpus, **When** it runs against 5.x and 6.x, **Then** every case
   agrees on cache contents and on the thrown exception type.
2. **Given** a documented behaviour that 5.x got wrong (DF-11 silent 5s timeout), **When** the
   suite runs, **Then** the 6.x result is the documented correct one and the divergence is
   listed in the migration guide.

---

### User Story 3 - A merge semantics contract the project owns (Priority: P1)

Partial writes merge by an explicit rule owned by this repository: an omitted field never
overwrites an existing value. TTL, eviction, and invalidation are options on that contract.

**Why this priority**: it resolves DF-06, closes 5.x issue #3 and `6.x` issue #12, and it is
the clearest demonstration that the architecture changed — the policy lives in `domain`, not
inside a third-party normalizer.

**Independent Test**: unit tests over the merge contract with partial inputs, plus property
tests that a merge followed by a read returns the union of provided and previously cached
fields.

**Acceptance Scenarios**:

1. **Given** a cached entity with three fields, **When** an optimistic write supplies two,
   **Then** the third field retains its prior value.
2. **Given** a type configured with a TTL, **When** the TTL elapses, **Then** the entity is
   reported as expired and refetched according to the fetch policy.
3. **Given** a storage size limit, **When** it is exceeded, **Then** the oldest entries are
   evicted and the eviction is observable.

---

### User Story 4 - Every failure is typed, complete, and never double-reported (Priority: P1)

A timeout, a cancellation, a cache miss, a transport error, and a GraphQL error are five
distinct typed exceptions. Each carries its cause and stack. No future or stream controller is
completed twice, and no error is swallowed.

**Why this priority**: it closes DF-07, DF-11, and the class of bug that 5.2.5 had to fix by
patching `QueryManager` with `isCompleted` guards.

**Independent Test**: each failure mode has a test that asserts the exact exception type, its
fields, and that exactly one completion occurs. A stress test fires a response after a timeout
and asserts no unhandled async error escapes the zone.

**Acceptance Scenarios**:

1. **Given** a response that arrives after the timeout, **When** it is delivered, **Then** it
   is dropped, logged once, and no second completion is attempted.
2. **Given** a cancelled operation, **When** the cancellation propagates, **Then** the caller
   receives a `CancelledException` carrying the cancellation reason.

---

### User Story 5 - Transport is replaceable: http, dio, websocket, AppSync (Priority: P2)

`HttpLink`, a dio link, a websocket link, and an AppSync REALTIME serializer all implement the
same contract and are selected by configuration. Swapping transport does not touch the domain
or the widgets.

**Why this priority**: it closes DF-09 and the `6.x` issues #7 (cookies), #13 (dio) and #16
(AppSync). It is P2 because it needs the contracts from stories 1-4 to exist first.

**Independent Test**: the conformance suite from User Story 2 runs against each transport
implementation; each has its own test package.

**Acceptance Scenarios**:

1. **Given** an application using `dio` for REST, **When** it configures the dio link,
   **Then** interceptors, timeouts, and cookie handling apply to GraphQL requests.
2. **Given** an AppSync endpoint, **When** a subscription is opened, **Then** the REALTIME
   handshake and per-message authorization are performed by the transport, not the app.

---

### User Story 6 - Offline mutation queue and isolate-backed cache (Priority: P3)

Mutations made offline are queued, ordered, and replayed on reconnect with an idempotency key.
Normalization, parsing, and persistence can run off the UI isolate behind the same API.

**Why this priority**: both close `6.x` issues (#11, #9) and both depend on the repository
contracts from stories 1 and 3. They are last because they are the largest and least
blocking.

**Independent Test**: the queue is tested with a fake connectivity source and a fake transport;
the isolate-backed cache is benchmarked against the in-memory implementation on a large
normalized graph.

**Acceptance Scenarios**:

1. **Given** a disconnected client, **When** three mutations are made, **Then** all three are
   persisted in order and replayed exactly once on reconnect.
2. **Given** a cache of 10,000 entities, **When** it is persisted, **Then** the encode does not
   block the UI isolate beyond a measured threshold.

---

### Edge Cases

- **A conformance case 5.x fails.** The suite must distinguish "5.x is right, 6.x regressed"
  from "5.x is wrong, 6.x fixes it". Every divergence is enumerated in the migration guide.
- **A partial write to a non-normalized (scalar) field.** The merge contract must define
  whether `null` is an omission or a deliberate clear, per field.
- **A timeout that races cancellation.** Both must produce exactly one terminal event, with the
  first one winning.
- **Reconnect while a subscription is mid-handshake.** Connection state transitions must be
  monotonic and idempotent.
- **A dependency that only exists on `dart:io`.** The domain must not import it; the adapter
  selects at the edge.
- **The `zfa` generator and hand-written code.** Generated files are never edited; if the
  generator cannot express a requirement, the requirement is wrong or the generator is extended,
  not worked around.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The package MUST be layered `domain` → `data` → `presentation`, with dependencies
  pointing inward only, enforced by a CI import-boundary check.
- **FR-002**: `domain` MUST NOT import Flutter, `http`, `gql_*`, `hive_ce`, or `dart:io`.
- **FR-003**: Every design failure DF-01…DF-13 in
  `../001-5x-hardening/DESIGN_FAILURES.md` MUST be resolved, deferred with a recorded reason, or
  explicitly accepted in this specification.
- **FR-004**: A conformance suite MUST exist and MUST be runnable against both 5.x and 6.x.
- **FR-005**: The cache merge contract MUST be owned by this repository, MUST specify partial
  writes, TTL, eviction, and invalidation, and MUST be covered by property tests.
- **FR-006**: Every failure mode MUST map to a distinct typed exception carrying cause and
  stack; no completion MAY occur twice; no error MAY be swallowed.
- **FR-007**: There MUST be no package-level mutable configuration. Equality functions, timeouts,
  and cache policies MUST be per-client dependencies.
- **FR-008**: Transport MUST be pluggable behind one contract, with http, dio, websocket, and an
  AppSync serializer provided.
- **FR-009**: The public API MUST be an explicit curated barrel, verified against a golden list
  in CI.
- **FR-010**: The TDD cycle (red → green → refactor) MUST be followed for every behavioural
  change; the constitution is binding.
- **FR-011**: Client and cache MUST be constructed by the application and injected; the widgets
  package MUST NOT construct a cache implementation.
- **FR-012**: The offline mutation queue MUST persist, order, and replay mutations exactly once.
- **FR-013**: Normalization, parsing, and persistence MUST be able to run off the UI isolate
  without an API change.
- **FR-014**: Code generation MUST go through the Zuraffa (`zfa`) toolchain; generated files MUST
  NOT be hand-edited.
- **FR-015**: A migration guide MUST enumerate every behavioural difference from 5.x.

### Key Entities

- **`Operation`** — a parsed GraphQL document plus variables and operation type.
- **`OperationResult`** — typed parsed data, or a typed exception; never both.
- **`CacheEntity`** — a normalized node: id, type, field map, expiry metadata.
- **`CacheRepository`** (contract) — read, write, merge, invalidate, evict, persist.
- **`Transport`** (contract) — execute an operation, emit connection state, surface typed
  transport failures.
- **`MutationQueueEntry`** — operation, idempotency key, attempt count, next-attempt time.
- **`ConnectionState`** — disconnected / connecting / connected / reconnecting.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of conformance cases agree between 5.x and 6.x, with every intentional
  divergence documented.
- **SC-002**: Zero import-boundary violations across the whole `lib/` tree.
- **SC-003**: Coverage of `domain` ≥ 95%; overall `lib/` coverage ≥ 85%.
- **SC-004**: All 7 `6.x`-labelled issues are closed by a named requirement in this spec or
  moved to a tracked follow-up.
- **SC-005**: All 13 design failures are resolved or explicitly accepted.
- **SC-006**: A benchmark on a 10,000-entity cache shows persistence and normalization do not
  exceed the UI-frame budget on the reference device.
- **SC-007**: `graphql_flutter_plus` 6.x widget tests pass against the new client with no
  changes to widget test intent (only to setup).

## Assumptions

- `6.x` is permitted to break the public API; `5.x` is the maintenance line for users who
  cannot migrate.
- The `5.x` line continues to receive bug fixes during the 6.x development window.
- The Zuraffa (`zfa`) toolchain is available and will be extended where it cannot express a
  requirement, rather than bypassed.
- `normalize` may be replaced, vendored, or wrapped; it is not a fixed dependency of 6.x.
- Widgets keep their current names and semantics (`Query`, `Mutation`, `Subscription`,
  `GraphQLProvider`) so application code migrates by import change plus setup change.
- The conformance corpus is derived from 5.x's existing test suite plus the mirrored upstream
  issue reports.
- No `package:graphql` compatibility shim is required; 6.x is a new package version, not a
  drop-in.

## Out of Scope

- Changing the GraphQL semantics of the protocol itself (fragments, aliases, directives).
- Server-side code generation or schema tooling beyond what `zfa` provides.
- A migration codemod; the migration guide is documentation only.