# Bug Fix: Subscriptions enter an infinite connect/disconnect loop

- **Slug**: subscription-content-length-zero
- **Fixed**: 2026-11-13
- **Assessment**: ./assessment.md
- **Status**: applied

## Summary

`_disconnectOnKeepAliveTimeout` force-closed the socket whenever no server `ConnectionKeepAlive`
arrived within `inactivityTimeout` (default 30s). Servers that never send protocol keepalives —
Apollo Server 3+, NestJS — therefore had every healthy, idle subscription closed and
auto-reconnected forever. The watchdog is now armed only after the peer has shown it sends
keepalives.

## Changes

| File | Change | Notes |
|------|--------|-------|
| `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart` | modified | `_disconnectOnKeepAliveTimeout` tracks whether any keepalive was seen; the first timeout without one closes the watchdog subscription, not the socket |
| `packages/graphql_plus/test/websocket_test.dart` | added tests | new `SocketClient keepalive watchdog` group (2 tests) |

## Diff Highlights

```dart
// before — a peer that never sends `ka` hit this unconditionally
messages.whereType<ConnectionKeepAlive>().timeout(
  config.inactivityTimeout!,
  onTimeout: (event) { event.close(); unawaited(_closeSocketChannel()); },
).listen(null);

// after
var sawKeepAlive = false;
messages.whereType<ConnectionKeepAlive>().timeout(
  config.inactivityTimeout!,
  onTimeout: (event) {
    event.close();
    if (sawKeepAlive) unawaited(_closeSocketChannel());
  },
).listen((_) { sawKeepAlive = true; });
```

## Tests Added or Updated

- `test/websocket_test.dart` → `SocketClient keepalive watchdog`:
  - *graphql-ws: a peer that never sends ConnectionKeepAlive is left connected* — the
    regression test for #15. Runs a real `HttpServer` that completes the `graphql-ws` handshake
    and never sends `ka`, with `inactivityTimeout: 200ms`, and asserts the connection state
    never becomes `notConnected` after 700ms.
  - *graphql-ws: a peer whose ConnectionKeepAlive stops is still closed* — preserves the
    dead-connection detection for peers that do send `ka`.

Both use a locally bound `HttpServer` on an ephemeral port; no network access.

## Local Verification

- **Red/green on the regression test.** With the fix stashed, the first test fails:
  `Expected: false / Actual: <true>` (`sawDisconnect`). With the fix, it passes. This is the
  evidence that the test actually exercises the defect.
- `dart analyze --fatal-infos` → **No issues found!**
- `dart test test/websocket_test.dart` → **26/26 pass** (including the two new tests)
- `dart format --set-exit-if-changed .` → clean

### A wrong assertion, corrected

The first version of the regression test asserted `socketChannel!.closeCode, isNull`. That
**passed on unfixed code**, because `closeCode` is not set synchronously when the client closes
its own sink — the assertion was vacuous. It was replaced with a listener on `connectionState`
that flags any `notConnected` transition, which is the actual observable effect and which does
fail without the fix.

### A test bug worth recording

The second test initially created the keepalive timer *after* sending `connection_ack`, so
`kaTimer?.cancel()` in the test raced the assignment and never cancelled anything (96 `ka`
messages over 5s). The timer is now created before the ack, which makes cancellation
deterministic.

## Deviations from Assessment

- The assessment's preferred fix is implemented as written (two-stage watch).
- The assessment also noted a separate `graphql-transport-ws` defect: `_enqueuePing` is re-armed
  only on `pong`, so a peer that ignores pings yields exactly one ping and then permanent
  silence. **Not fixed here** — it is not the reported loop (that path never force-closes), and
  changing ping behaviour has a wider blast radius. Recorded as a follow-up.

## Follow-ups

- `CHANGELOG.md`: document the `inactivityTimeout` / `autoReconnect` interaction, which the
  upstream thread shows is not discoverable, and recommend `Duration.zero` to disable.
- Fix the `graphql-transport-ws` single-ping defect in a separate change.
- The issue's `content-length: 0` theory does not reproduce on Dart 3.14 (the handshake was
  captured and carries no such header); that finding is recorded in `assessment.md`.