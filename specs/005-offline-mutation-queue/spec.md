# Feature Specification: Offline mutation queue

**Feature Branch**: `feat/issue-11`

**Created**: 2026-11-13

**Status**: Draft

**Input**: "Offline mutation queue (Original Issue #201)" —
https://github.com/arrrrny/graphql_plus/issues/11 (mirrors upstream
`graphql-flutter#201`)

## Problem

The offline cache keeps query data, but a mutation made while the device has no
connectivity is lost: `GraphQLClient.mutate` resolves with a network exception
and nothing is retried. The caller has to detect the failure, persist the
operation itself, and replay it by hand — in the right order, without sending
the same write twice.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A mutation made offline is kept and replayed on reconnect (Priority: P1)

A user edits a document on a train. The app calls `mutate`; the device is
offline. The mutation is written to the queue, the caller learns it was queued
(and gets its queue id), and when connectivity returns the mutation is sent
without the caller doing anything.

**Why this priority**: it is the request. Losing a write is data loss, and
without the queue every app reimplements the same retry loop.

**Independent Test**: a `ManualConnectivityMonitor` that starts offline, a
recording link; call `mutate`, assert the link saw nothing and the queue holds
one entry, flip the monitor online, assert the recording link saw exactly the
queued mutation.

**Acceptance Scenarios**:

1. **Given** an offline client, **When** a mutation is executed, **Then** the
   mutation is appended to the queue and the returned result carries an
   `OfflineMutationException` naming the queue id.
2. **Given** connectivity returns, **When** the monitor reports online, **Then**
   every queued mutation is sent through the wrapped link.
3. **Given** an app that wants to know when the write landed, **When** a queued
   mutation is delivered, **Then** `OfflineMutationLink.onDelivered` emits it
   with the server's response.

---

### User Story 2 - The queue keeps its promises about order and identity (Priority: P1)

Two mutations are made offline in a row; they are replayed in that order. The
same mutation made twice offline is stored once, and a replayed request carries
the idempotency key so a server can tell a retry from a new write.

**Why this priority**: order and idempotency are the difference between a queue
and a list of requests. A replay that reorders writes corrupts state, and a
replay the server cannot deduplicate double-charges the user.

**Independent Test**: enqueue `A`, `B`; enqueue `A` again; assert the queue is
`[A, B]`, and that `A.asRequest.context` carries `OfflineIdempotencyKey`.

**Acceptance Scenarios**:

1. **Given** two different mutations queued offline, **When** the queue is
   flushed, **Then** they are sent one at a time, oldest first.
2. **Given** an identical mutation is queued twice (same document, operation
   name and variables), **When** it is enqueued again, **Then** the existing
   entry is returned and the queue length is unchanged.
3. **Given** a replayed request, **When** it reaches the wrapped link, **Then**
   its context carries the entry's `OfflineIdempotencyKey`.
4. **Given** a flush whose send fails for transport reasons, **When** the send
   throws, **Then** that entry stays at the head with `attempts` incremented and
   no later entry is sent.

---

### User Story 3 - The queue survives a restart (Priority: P2)

The app is killed while a mutation is queued. On the next launch the entry is
still there, in order, and is replayed when connectivity returns.

**Why this priority**: a queue that lives in memory only loses the write the
moment the OS reclaims the process, which is most of what P1 is for. It is P2
because the default store is in-memory and a host app supplies the durable one.

**Independent Test**: enqueue through a `MutationQueueStore`, build a second
queue over the same store, assert the entry is restored with its id, payload
and idempotency key.

**Acceptance Scenarios**:

1. **Given** a queue backed by a store, **When** it is rebuilt from that store,
   **Then** the entries come back in order with their payloads intact.
2. **Given** a delivered entry, **When** the store is read again, **Then** the
   entry is gone.

---

## Requirements

### Functional

- **FR-001**: `OfflineMutationQueue` MUST accept a mutation (document, operation
  name, variables) and return a stable id.
- **FR-002**: The queue MUST expose its pending entries oldest-first, its length
  and its head, without copying the store on every read.
- **FR-003**: The queue MUST deduplicate identical payloads by default and MUST
  allow the deduplication to be turned off at construction.
- **FR-004**: Every entry MUST carry an idempotency key derived
  deterministically from the payload (variable order MUST NOT matter), and a
  caller-supplied key MUST be used verbatim.
- **FR-005**: An entry MUST serialize to and from a JSON map without losing its
  payload, id, key, attempt count or last error.
- **FR-006**: Persistence MUST go through a `MutationQueueStore` abstraction; an
  in-memory store MUST be provided as the default.
- **FR-007**: `flush` MUST send entries one at a time, oldest first, MUST remove
  each entry once its send succeeded, and MUST stop at the first failure.
- **FR-008**: A failed send MUST leave its entry at the head with `attempts`
  incremented and `lastError` recorded.
- **FR-009**: `OfflineMutationLink` MUST pass queries, subscriptions and online
  mutations straight to the link it wraps.
- **FR-010**: `OfflineMutationLink` MUST queue an offline mutation and resolve
  the caller's request with an `OfflineMutationException` carrying the queue id.
- **FR-011**: `OfflineMutationLink` MUST replay the queue, in order, when
  `ConnectivityMonitor` reports online, and MUST emit each delivered mutation
  with the response it received.
- **FR-012**: A response carrying GraphQL errors MUST count as delivered — the
  server answered — and MUST be surfaced on the delivery stream.
- **FR-013**: A transport failure during replay MUST be surfaced on a failure
  stream and MUST leave the mutation queued.
- **FR-014**: A queue at `maxEntries` MUST refuse a new entry with a
  `MutationQueueFullException` rather than grow without bound.

### Non-functional

- **NFR-001**: The queue lives in the link layer; `QueryManager` is unchanged.
- **NFR-002**: No new runtime dependency: serialization uses
  `package:gql/language.dart`'s `printNode` and `dart:convert`.
- **NFR-003**: The module is pure Dart, so it runs on the client package's own
  test suite (`dart test`).

## Design

`packages/graphql_plus/lib/src/offline/`

- `connectivity.dart` — `ConnectivityMonitor` (abstract: `isOnline`,
  `onConnectivityChanged`, `dispose`) and `ManualConnectivityMonitor` for hosts
  and tests that drive the state themselves.
- `mutation_queue.dart` — `QueuedMutation` (payload + serialization +
  `asRequest`), `MutationQueueStore` / `InMemoryMutationQueueStore`,
  `OfflineMutationQueue`, `OfflineIdempotencyKey` context entry, and
  `offlineIdempotencyKeyFor`.
- `offline_mutation_link.dart` — `OfflineMutationLink`, `DeliveredMutation`,
  `OfflineMutationFailure`, `OfflineMutationException`,
  `MutationQueueFullException`.
- `offline.dart` — barrel, re-exported from `graphql_plus.dart`.

A host wires it by wrapping its terminating link:

```dart
final queue = OfflineMutationQueue(store: myDurableStore);
final link = OfflineMutationLink(
  forward: HttpLink(uri: uri),
  connectivity: connectivityMonitor,
  queue: queue,
);
final client = GraphQLClient(link: link, cache: cache);
```