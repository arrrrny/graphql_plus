# Implementation Plan: 6.x — clean-architecture rewrite

**Branch**: `002-6x-rewrite` | **Spec**: [spec.md](./spec.md) | **Created**: 2026-11-12

## Summary

Replace the 5.x client with a layered implementation: a `domain` that owns operation semantics,
cache merge/TTL policy, and typed failures; a `data` layer of adapters (http, dio, websocket,
AppSync, hive/isolate persistence) implementing domain contracts; and the existing widgets
layer reduced to presentation over injected interfaces. Parity with 5.x is proven by a conformance
suite run against both clients. Structure and scaffolding come from the Zuraffa (`zfa`) toolchain.

## Technical Context

**Language**: Dart 3 / Flutter
**Architecture**: clean architecture (`domain` → `data` → `presentation`), one inward direction
**Scaffolding**: `zfa` (available at `~/.local/bin/zfa`); generated files are never hand-edited
**State**: streams (`Stream<OperationResult>`, `Stream<ConnectionState>`) owned by use cases
**DI**: constructor injection from the application; no service locator
**Testing**: `package:test` for `domain`/`data`; `flutter_test` for widgets; `test` conformance
package shared by both clients
**Source root**: `packages/graphql_plus/lib/{domain,data}` + `packages/graphql_flutter_plus/lib`

## Constitution Check

| Principle | How this plan satisfies it |
| --- | --- |
| I. Test-first | Every phase starts with the failing test; phase 0 builds the conformance corpus before any implementation |
| II. Clean architecture | Enforced by a CI import-boundary check on `domain/` |
| III. API compatibility | Not applicable — 6.x is the designated breaking release |
| IV. Fail loud | One exception hierarchy, no double completion, no swallowed errors (US4) |
| V. Simplicity / YAGNI | No speculative abstraction; the offline queue and isolate cache come last |

## Design Decisions

### D1 — Package layout

```
packages/graphql_plus/lib/
  graphql_plus.dart                 # curated public barrel (golden-file checked)
  src/
    domain/
      operation/                    # Operation, OperationType, variables, document
      result/                       # OperationResult, ParsedData
      cache/                        # CacheEntity, CacheRepository, MergePolicy, TtlPolicy
      subscription/                 # ConnectionState, SubscriptionSession (contract)
      failure/                      # GraphQLOperationFailure hierarchy
    data/
      transport/http/               # HttpTransport, DioTransport
      transport/websocket/          # WsTransport, AppSyncSerializer
      cache/                        # NormalizingCacheRepository, HiveCacheStore, MemoryStore
      parsing/                      # ResponseDecoder, NormalizationAdapter
      queue/                        # PersistedMutationQueue
    infrastructure/
      isolate/                      # IsolateCacheWorker
packages/graphql_flutter_plus/lib/src/
  widgets/                          # Query, Mutation, Subscription, GraphQLProvider, Consumer
  hooks/                            # useQuery, useMutation, useSubscription
```

`domain/` imports nothing outside `dart:core`/`dart:async`. Everything else sits in `data/` or
`infrastructure/`.

### D2 — Failure model

A sealed `OperationFailure` hierarchy in `domain/failure`: `TransportFailure` (with cause and
stack), `TimeoutFailure`, `CancelledFailure`, `CacheMissFailure`, `GraphqlErrorFailure`,
`NormalizationFailure`. `OperationResult` is either `OperationSuccess(data)` or
`OperationFailureResult(failure)` — never both, never a nullable payload. This directly closes
DF-05, DF-07, DF-11.

### D3 — Cache contract

`CacheRepository` in `domain/cache` with `read`, `write`, `merge`, `invalidate`, `evict`,
`entriesFor(type)`, `persist`. Partial writes merge by the rule *"an absent field is not an
instruction"* (closes DF-06 and 5.x issue #3). TTL and size limits are policy objects, not
fields on the store (closes 6.x issue #12). `NormalizingCacheRepository` is the only adapter that
knows about `normalize`.

### D4 — Conformance parity

A `test/conformance` package with a corpus of `{document, variables, fixtures, expected cache,
expected failure}` cases. It runs against 5.x (as a reference implementation) and 6.x. Every
intentional divergence is listed in `MIGRATION-6x.md` with the 5.x behaviour, the 6.x behaviour,
and the reason.

### D5 — Transport

One `Transport` contract: `Stream<OperationResult> execute(Operation)`,
`Stream<ConnectionState> connectionState`, `Future<void> close()`. Implementations:
`HttpTransport` (package:http), `DioTransport`, `WebSocketTransport`, `AppSyncTransport`
(serializes the REALTIME envelope and per-message authorization). Interceptors and cookies live
in the adapters, so `6.x` issues #7, #13 and #16 are adapter work, not core work.

### D6 — Generation

`zfa` generates the layer skeleton, the contracts, and the DI wiring. Hand-written code is the
policy bodies. If `zfa` cannot express something (e.g. the merge policy), extend `zfa` rather
than hand-writing in a generated file.

## Phases

| Phase | Goal | Exit criterion |
| --- | --- | --- |
| 0 | Conformance corpus + boundary check | Corpus runs against 5.x; boundary check fails on a deliberate violation |
| 1 | `domain` skeleton, no transport | Domain tests green with fakes only |
| 2 | `OperationResult` / failure model | US4 tests green |
| 3 | `CacheRepository` + merge/TTL/eviction | Property tests green |
| 4 | `HttpTransport` + `WebSocketTransport` | Conformance green on both |
| 5 | `DioTransport` + `AppSyncTransport` | Per-transport conformance green |
| 6 | Widgets ported to injected interfaces | Widget tests pass unchanged in intent |
| 7 | Offline queue | US6 first half green |
| 8 | Isolate cache | Benchmark within budget |

## Risks

| Risk | Mitigation |
| --- | --- |
| Parity drift nobody notices | Conformance suite is the gate for 6.0.0; divergences are enumerated |
| Rewriting before the corpus exists produces unverifiable work | Phase 0 precedes everything |
| `zfa` cannot express the domain model | Time-boxed evaluation in phase 1; fall back to hand-written scaffolding with the same layout |
| The 5.x maintenance line stalls during the rewrite | 5.x bug fixes continue on their own branch; the four `5.x` issues are spec'd independently |
| Widgets port becomes a second rewrite | Widgets keep their public names and semantics; only construction changes |