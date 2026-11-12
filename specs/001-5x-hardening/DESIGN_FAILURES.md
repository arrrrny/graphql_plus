# 5.x Design-Failure Audit

Evidence-backed inventory of the architectural defects in `graphql_plus` 5.2.6 /
`graphql_flutter_plus` 5.3.2 that a 6.x rewrite must not reproduce.

Every finding below is observable in the tree as it stands today (commit `4eee571`). Each is
classified as **structural** (the design causes it), **leakage** (an implementation detail
escapes its layer), or **operational** (the code misbehaves at a level the design should have
prevented).

Scope: 9,003 lines of `lib/` across both packages; 2,885 of them in
`packages/graphql_plus/lib/src/core`.

---

## DF-01 — `QueryManager` is a god object *(structural)*

`QueryManager` (`packages/graphql_plus/lib/src/core/query_manager.dart`, 749 lines) owns:
link invocation, timeout enforcement, cache reads and writes, optimistic-transaction
lifecycle, cancellation, rebroadcast decisions, and query registration. It is constructed
with six collaborators and immediately reaches back into its own owner through
`QueryScheduler(queryManager: this)`.

**Why it matters**: every fix in the 4-issue `5.x` set and every cache/TTL request in the
`6.x` set touches this file. A change to polling can alter timeout behaviour because they
share a method body.

**6.x resolution**: separate use cases — `ExecuteOperation`, `ReadFromCache`, `WriteToCache`,
`ManageOptimisticLayer`, `SchedulePolling` — composed by a `GraphQLClient` that holds no
logic.

---

## DF-02 — Circular ownership between `QueryManager` and `QueryScheduler` *(structural)*

`QueryScheduler` takes `QueryManager?` in its constructor, and `QueryManager` constructs the
scheduler inside its own constructor body. Each can reach the other. Polling state
(`registeredQueries`, `intervalQueries`, `_pollingTimers`) lives in the scheduler; the query
lifecycle lives in the manager.

**Why it matters**: teardown ordering is unstated. A closed query can still be registered,
and the `retainWhere` cleanup in `fetchQueriesOnInterval` exists specifically to repair that.
It is a symptom of the cycle, not a fix for it.

**6.x resolution**: one owner of query lifecycle (an `ObservableQueryRegistry`); the scheduler
receives a stream of registry changes and owns no query state.

---

## DF-03 — Global mutable static state as a configuration channel *(leakage)*

`QueryManager`'s constructor assigns to **top-level mutable variables**:

```dart
if (deepEquals != null)  gqlDeepEquals = deepEquals;
if (asyncDeepEquals != null) gqlAsyncDeepEquals = asyncDeepEquals;
```

(`packages/graphql_plus/lib/src/core/query_manager.dart:54-58`)

**Why it matters**: two clients with different equality functions silently overwrite each
other. The last-constructed client wins for the whole process, including for caches owned by
the first client. This is not testable in isolation and not reportable as a bug from the
outside.

**6.x resolution**: equality functions are per-client dependencies; no package-level mutable
configuration exists.

---

## DF-04 — The public API is "whatever `src/` exports" *(leakage)*

`packages/graphql_plus/lib/graphql_plus.dart` is a barrel that re-exports whole directories:

```dart
export 'package:graphql_plus/src/cache/cache.dart';
export 'package:graphql_plus/src/core/core.dart';
export 'package:graphql_plus/src/core/policies.dart';
export 'package:graphql_plus/src/exceptions.dart';
export 'package:graphql_plus/src/graphql_client.dart';
export 'package:graphql_plus/src/links/links.dart';
```

**Why it matters**: every internal refactor is a potential breaking change, because
`package:graphql_plus/src/**` is reachable by importers. There is no supported-API boundary to
check a change against. Note also the dead `library graphql;` directive at the top of a
package named `graphql_plus`.

**6.x resolution**: explicit, hand-curated public barrel; `src/` not importable (or not
exported); API surface verified against a golden list in CI.

---

## DF-05 — `QueryResult` is typed on `Object?` with `Map<String, dynamic>` data *(leakage)*

`QueryResult<TParsed extends Object?>` (`src/core/query_result.dart:43`) carries
`Map<String, dynamic>? data`, and its `data` getter/setter pair casts at runtime. Every
generic `T` in the public API (`mutate<TParsed>`, `watchQuery<TParsed>`) is therefore a claim
the type system cannot enforce.

**Why it matters**: the generic parameter buys no safety; it only moves the cast. The
`as Map<String, dynamic>?` casts at `query_manager.dart:104` and `:607` are the visible cost.

**6.x resolution**: a parsed-response value object with a typed `data` accessor, and a
separate raw-response type for the unparsed path.

---

## DF-06 — Cache normalization is owned by a third-party package, not by the domain *(structural)*

`normalize` is imported directly by 8 files under `src/`, including `cache/cache.dart`,
`cache/_normalizing_data_proxy.dart`, `cache/hive_store.dart`, and
`core/query_manager.dart`. The library's core value proposition — normalized caching — is
implemented outside the repository and reached for directly.

**Why it matters**: `PartialDataCachePolicy` semantics, `TypePolicy`, `dataIdFromObject`, and
`acceptPartialData` are all delegated. Issue #3 (partial `optimisticResult` nulling existing
fields) is a direct consequence: the write path is
`OptimisticProxy.writeNormalized` → `normalize` → patch map, with no merge contract owned by
this codebase. The same coupling blocks #12 (TTL/eviction).

**6.x resolution**: a domain `CacheRepository` contract with a normalization adapter; the
merge and eviction policies are this project's code and its tests.

---

## DF-07 — Two parallel exception hierarchies *(operational)*

`src/exceptions/exceptions.dart` and `src/exceptions/exceptions_next.dart` both exist, and
`exceptions_next.dart` begins with the comment *"Once `gql_link` has robust http and socket
exception handling, these should be the only exceptions we need"* — a note that has been
waiting on an upstream release since the fork point. `CancelledException` extends
`LinkException` and passes `null, null` for the parent's fields.

**Why it matters**: `catch` sites cannot know which hierarchy a failure arrives in.
`CancelledException` deliberately discards its `originalException`/stack, which is why
"fail loud" is not enforceable today.

**6.x resolution**: one exception hierarchy owned in `domain`, with typed transport
exceptions mapped into it at the link boundary.

---

## DF-08 — Transport, parsing, and normalization all run on the caller's isolate *(structural)*

There is no isolate boundary anywhere in `src/`. `helpers.dart` and `utilities/` do
parse/serialize work inline, and `hive_store.dart` persists synchronously on the calling
isolate. `gqlAsyncDeepEquals` exists (DF-03's second static) specifically to allow a caller
to smuggle in async comparison, which is the only accommodation made for this problem.

**Why it matters**: this is upstream issue #424 in its entirety, and it is why it is deferred
to 6.x rather than patched.

**6.x resolution**: encode/decode/persist are async operations behind a repository contract
that may be isolate-backed without the public API changing.

---

## DF-09 — `Link` composition is stringly-typed and order-dependent *(leakage)*

Links are composed as a `Link` chain with `Request`/`Response` context mutated by each link
(`auth_link.dart`, `cancellable_http_link/`). `Response.context` is a mutable map, so
downstream links read keys that upstream links must have written, with no type or compile-time
check. Issue #8 (replay after `setContext`) fails because replay has no defined owner.

**Why it matters**: link order is a correctness-critical, invisible configuration. Adding a
link can silently break auth refresh.

**6.x resolution**: typed middleware with declared inputs/outputs; replay is a first-class
operation with an explicit retry policy.

---

## DF-10 — Subscription connection state is internal and unobservable *(operational)*

`websocket_client.dart` tracks connection lifecycle and calls `onConnectionLost` internally
(referenced by upstream reports #1379 and #1426 as a null-check crash site), but no public
stream exposes it. Consumers cannot tell "disconnected" from "no events yet".

**Why it matters**: this is issue #6, and the fact that the state exists but is unreachable is
the clearest single example of DF-04/DF-09 in the subscription path.

**6.x resolution**: a `ConnectionState` stream owned by the subscription use case.

---

## DF-11 — Hard-coded silent defaults *(operational)*

`requestTimeout: const Duration(seconds: 5)` in `QueryManager` is the default behind the
timeout/completer bug that 5.2.5 fixed. A silent default that fires on the happy path is a
design decision disguised as a constant: the user is never told a timeout occurred, only that
their request failed.

**Why it matters**: 5.2.5's hardening prevents the *crash*; it does not address the fact that
the default itself is unsafe and invisible. Upstream issues #1453, #1470, #1494, #1535 all
descend from this one value.

**6.x resolution**: no default timeout; timeouts are explicit per-client configuration and a
timeout surfaces a typed exception on the result.

---

## DF-12 — Widget layer holds client wiring *(structural)*

`graphql_flutter_plus/lib/src/widgets/cache_provider.dart` and `graphql_provider.dart` carry
cache and client construction. The widget layer knows which cache implementation is in use.
`CacheProvider`'s only reason to exist is to build a `ValueNotifier<GraphQLClient>` around a
`GraphQLCache` (the question upstream #791 asks about).

**Why it matters**: a widgets package cannot be tested or replaced without dragging in the
cache implementation. It also means the Flutter package, not the client, owns a policy
decision.

**6.x resolution**: client and cache are constructed by the application and injected; widgets
read from an interface.

---

## DF-13 — The monorepo's quality gate is unenforceable as written *(operational)*

`melos.yaml` runs `flutter analyze . --fatal-infos` over the whole package including
`example/` and `test/`. On a Flutter version where `package:flutter/material.dart` is
deprecated (3.47.0+), that command fails for reasons unrelated to any change under review.
Separately, `Makefile` declares `flutter:` → `ci_check_flutter` and `ci_fmt_flutter` →
`client_analyze` — the Flutter format target runs the **client's** analyzer.

**Why it matters**: a red or wrong gate is worse than no gate, because contributors learn to
ignore it.

**6.x resolution**: analyze/test are scoped per package and per tree (`lib/` is fatal, `example/`
is advisory), and the Makefile targets are corrected.

---

## Accepted-for-5.x *(not defects to fix on 5.x)*

| Item | Why accepted |
| --- | --- |
| `package:flutter/material.dart` in `example/` and `test/` | Material-migration, unrelated to this line; only surfaces on Flutter 3.47.0+ |
| 4 dependencies with newer incompatible versions (`dart pub outdated`) | Constitution forbids dependency upgrades in a patch release |
| Upstream CHANGELOG history retained verbatim in the fork's CHANGELOGs | Provenance; rewriting it would misrepresent the fork point |
| `normalize` remaining a dependency | Replacing it is a 6.x rewrite (DF-06), not a patch fix |

---

## Mapping to release lines

| Finding | 5.x action | 6.x action |
| --- | --- | --- |
| DF-01, DF-02 | none (too large) | rewrite |
| DF-03 | none | rewrite |
| DF-04 | none (documentation only) | rewrite |
| DF-05 | none | rewrite |
| DF-06 | partial merge fix for issue #3 | rewrite |
| DF-07 | none | rewrite |
| DF-08 | none | rewrite |
| DF-09 | none | rewrite |
| DF-10 | additive `ConnectionState` stream for issue #6 | rewrite |
| DF-11 | documented | rewrite |
| DF-12 | none | rewrite |
| DF-13 | corrected `Makefile` targets (done in this release) | scope the analyzers |