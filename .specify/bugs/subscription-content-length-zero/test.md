# Bug Verification: Subscriptions enter an infinite connect/disconnect loop

- **Slug**: subscription-content-length-zero
- **Tested**: 2026-11-13
- **Assessment**: ./assessment.md
- **Fix**: ./fix.md
- **Result**: verified

## Summary

The loop no longer occurs: a `graphql-ws` peer that never sends `ConnectionKeepAlive` keeps its
connection open past the inactivity timeout, and the fix is proven necessary by a red/green run.
Dead-connection detection is preserved for peers that do send keepalives.

## Checks Performed

| Check | Command / Action | Result | Notes |
|-------|------------------|--------|-------|
| Reproduction (pre-fix) | `dart test test/websocket_test.dart --plain-name "a peer that never sends ConnectionKeepAlive"` with the fix stashed | fail | `Expected: false / Actual: <true>` — the connection was dropped |
| Reproduction (post-fix) | same, with the fix applied | pass | connection state never becomes `notConnected` |
| New / updated tests | `dart test test/websocket_test.dart --plain-name "keepalive watchdog"` | pass | 2/2 |
| Regression suite | `dart test test/websocket_test.dart` | pass | 26/26 |
| Lint / type-check | `dart analyze --fatal-infos` | pass | `No issues found!` |
| Formatting | `dart format --set-exit-if-changed .` | pass | 0 changed |

## Output Excerpts

Post-fix, both directions:

```
00:05 +1: SocketClient keepalive watchdog graphql-ws: a peer whose ConnectionKeepAlive stops is still closed
00:06 +2: All tests passed!
```

Pre-fix, the regression test:

```
Expected: false
  Actual: <true>
00:04 +0 -1: Some tests failed.
```

Also measured while diagnosing: the handshake `dart:io` sends contains **no** `content-length`
header (full header dump in `assessment.md`), so the issue title's stated cause does not
reproduce on Dart 3.14. The loop comes from the keepalive watchdog.

## Residual Risks

- **A genuinely dead connection to a silent peer is no longer detected by the keepalive
  watchdog.** It falls back to socket close/error detection. That is the trade the fix makes:
  a healthy idle subscription must survive.
- **The `graphql-transport-ws` single-ping defect is untouched.** `_enqueuePing` re-arms only on
  `pong`, so a peer that ignores pings gets one ping and then silence. It does not cause the
  reported loop (that path never force-closes), but it means keepalive is silently absent for
  such peers.
- **Not verified against the reporter's actual Cloud Run backend.** The fix was verified against
  a local server that reproduces the protocol condition (no `ka`), not against the original
  deployment.

## Recommendation

Close the bug — the loop is gone, the regression test fails without the fix and passes with it,
and no check implicates the change. Suggest also fixing the `graphql-transport-ws` ping defect in
a separate change, and documenting the `inactivityTimeout` / `autoReconnect` interaction.