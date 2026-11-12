# Tasks: Expose subscription connection state

**Spec**: [spec.md](./spec.md) | **Plan**: derived from spec + `.specify/memory/tdd-profile.md`

TDD order: each behaviour below was written as a failing test first, then made to pass.

## Phase 1 — Red (tests first)

- [x] T001 Add `WebSocketLink.connectionState` tests: `notConnected` before first connect (FR-003)
- [x] T002 Test: the loss is observable without touching `SocketClient` (FR-001, FR-007, SC-001)
- [x] T003 Test: a subscription survives `connectOrReconnect()` (FR-002, SC-002)
- [x] T004 Test: the stream closes after `dispose()` (FR-004)
- [x] T005 Prove red — `dart analyze` reported `The getter 'connectionState' isn't defined for
  the type 'WebSocketLink'` on all four

## Phase 2 — Green (implementation)

- [x] T006 Add a link-owned `BehaviorSubject<SocketConnectionState>` seeded with `notConnected`
- [x] T007 Expose `Stream<SocketConnectionState> get connectionState`
- [x] T008 Forward the current `SocketClient`'s state in `connectOrReconnect()`, cancelling the
  previous subscription so a rebuild cannot leak or duplicate
- [x] T009 Close the subject in `dispose()` and cancel its subscription (FR-004)
- [x] T010 Multiple listeners verified by the broadcast subject (FR-005) — covered implicitly by
  T002/T003 running alongside T004

## Phase 3 — Regression

- [x] T011 `dart analyze --fatal-infos` → No issues found! (FR-006, SC-004)
- [x] T012 `dart test test/websocket_test.dart` → 28/28 (SC-003)
- [x] T013 `dart format --set-exit-if-changed .` → clean

## Notes

- FR-006 (additive only) holds: nothing existing changed. `SocketClient.connectionState`,
  `WebSocketLink.getSocketClient`, and `connectOrReconnect()` keep their signatures and semantics.
- The existing four-value `SocketConnectionState` enum is unchanged; a dedicated `reconnected`
  value would be a breaking change and is out of scope (see spec Assumptions).
- The naive implementation — forwarding `getSocketClient!.connectionState` directly — was rejected
  because `connectOrReconnect()` disposes the client, which is exactly when the signal is needed.
  That is what T003 pins down.