# Feature Specification: Expose subscription connection state

**Feature Branch**: `003-subscription-connection-state`

**Created**: 2026-11-13

**Status**: Draft

**Input**: "Expose a way to detect when a subscription connection is lost" —
https://github.com/arrrrny/graphql_plus/issues/6 (mirrors upstream `graphql-flutter#1188`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An app learns the subscription dropped (Priority: P1)

An app with an open subscription is backgrounded, the device sleeps, or the network drops. The
subscription stops delivering events. The app can observe that the connection left `connected`
and is now reconnecting or disconnected, and refetch the data it was showing.

**Why this priority**: it is the whole point of the request. Without it, a subscription that
silently stops delivering events leaves the app serving stale data with no signal at all — the
exact failure the issue describes.

**Independent Test**: a widget or unit test connects a `WebSocketLink` to a server, asserts
`connected`, kills the server, and asserts the exposed stream reports the loss without any
application code reaching into the socket client.

**Acceptance Scenarios**:

1. **Given** a connected subscription, **When** the server closes the socket, **Then** the
   exposed connection state stream emits a state that is not `connected`.
2. **Given** a connection that was lost, **When** the client reconnects, **Then** the stream
   emits `connecting` and then `connected` again.
3. **Given** the app, **When** it reads the connection state, **Then** it needs no knowledge of
   `SocketClient`, no null check, and no cast.

---

### User Story 2 - The connection state survives a reconnect (Priority: P1)

`WebSocketLink.connectOrReconnect()` disposes the old `SocketClient` and builds a new one. An
app that subscribed to connection state before that call must keep receiving events after it,
on the same stream.

**Why this priority**: this is the defect that makes the naive implementation useless. A stream
bound to a `SocketClient` instance dies the moment the link rebuilds it, which is precisely
when the app needs the signal.

**Independent Test**: subscribe to the link's connection state, call `connectOrReconnect()`,
then close the new socket and assert the original subscription observes the loss.

**Acceptance Scenarios**:

1. **Given** a subscription made before `connectOrReconnect()`, **When** the link rebuilds its
   socket client, **Then** the original subscription is not closed and keeps forwarding.
2. **Given** repeated reconnects, **When** the link rebuilds several times, **Then** each
   rebuild's events are forwarded on the same stream with no duplicated or missed states.

---

### User Story 3 - The existing public surface keeps working (Priority: P2)

Applications that already use `SocketClient.connectionState` directly, or `WebSocketLink.getSocketClient`,
are unaffected.

**Why this priority**: this is a `5.x` change and the constitution forbids breaking the published
API. The new accessor is additive.

**Independent Test**: the existing websocket test suite passes unchanged.

**Acceptance Scenarios**:

1. **Given** the existing test suite, **When** it runs, **Then** every test still passes.
2. **Given** a caller using `getSocketClient`, **When** the link reconnects, **Then** the
   behaviour of `getSocketClient` is unchanged (it still returns the current instance).

---

### Edge Cases

- **No socket client yet.** `WebSocketLink` connects lazily on the first request. Reading the
  connection state before any request must yield `notConnected` rather than throwing or hanging.
- **Disposed link.** After `dispose()`, the stream closes; a late read must not throw.
- **Multiple listeners.** Two apps listening to the same link must both receive events.
- **A connect attempt that fails before reaching `connected`.** The app should see the failure
  state rather than a silent gap.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `WebSocketLink` MUST expose a `connectionState` stream of `SocketConnectionState`
  that reflects the current connection without requiring the caller to reach into `SocketClient`.
- **FR-002**: The exposed stream MUST remain valid across `connectOrReconnect()`; a subscription
  made before a rebuild MUST keep receiving events after it.
- **FR-003**: Reading the connection state before the first connection MUST emit
  `SocketConnectionState.notConnected` and MUST NOT throw or block.
- **FR-004**: After `dispose()`, the exposed stream MUST close and MUST NOT throw on late reads.
- **FR-005**: The stream MUST support multiple simultaneous listeners.
- **FR-006**: The change MUST be additive: no existing signature, default, or export changes.
- **FR-007**: A state change MUST be observable at the moment it happens, not only by polling.

### Key Entities

- **`SocketConnectionState`** (existing) — `notConnected`, `handshake`, `connecting`, `connected`.
- **`WebSocketLink.connectionState`** (new) — a stable broadcast stream of the above.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A test observes the connection loss through the link alone, with no reference to
  `SocketClient`.
- **SC-002**: A subscription created before `connectOrReconnect()` still receives events after
  it (no test previously covered this).
- **SC-003**: The full existing websocket suite passes unchanged.
- **SC-004**: `dart analyze --fatal-infos` is clean.

## Assumptions

- The existing four-state enum is sufficient; a dedicated "reconnected" value would be a
  breaking change and is out of scope. A `connected → connecting → connected` sequence conveys
  reconnection.
- Applications poll or listen; no Flutter widget is added in this change.
- `SocketClient.connectionState` remains public and unchanged.

## Out of Scope

- Auto-refetch on reconnect (the issue's suggested "documented pattern"; this feature provides
  the signal, not the policy).
- Adding states to `SocketConnectionState`.
- A Flutter-level widget or hook.