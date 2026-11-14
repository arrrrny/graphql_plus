# Bug Verification: A `graphql-transport-ws` peer that never answers `ping` loses its keepalive

- **Slug**: transport-ws-ping-keepalive
- **Tested**: 2026-11-14
- **Assessment**: ./assessment.md
- **Fix**: ./fix.md
- **Result**: verified (already fixed on `master`)

## Summary

All three findings are resolved on `master` and the suite is green. The verification is a
mutation run: each fix was reverted in turn and the test that pins it was confirmed to fail, so
the tests are not merely passing alongside a dead guard.

## Checks Performed

| Check | Command / Action | Result | Notes |
|-------|------------------|--------|-------|
| Analyzer | `dart analyze --fatal-infos` | pass | `No issues found!` |
| Full suite | `dart test -j 2` | pass | 254/254 at `4859a1c` |
| WebSocket suite | `dart test test/websocket_test.dart -j 2` | pass | 39/39, includes the whole keepalive group |
| Finding 1 red/green | re-add `_enqueuePing()` to the `pong` branch, run `keeps pinging a peer that chatters unsolicited pongs` | **fails as expected** | ping starves under pong chatter — the exact defect the finding describes |
| Finding 2 red/green | remove the `_pongDeadline = Timer(…)` arm, run `closes the connection when a ping goes unanswered past the deadline` | **fails as expected** | connection never reaches `notConnected` |
| Finding 3 | the keepalive test awaits `pings >= 3` instead of a fixed 750ms sleep + `greaterThan(1)` | pinned | a two-ping-then-dead timer cannot pass |
| Mutation revert | restore both files, `git diff --stat` | clean | tree byte-identical to `master` |

## Recommendation

Close the bug and close issue #55 — every finding is fixed on `master`, each fix is pinned by a
test that fails when it is reverted, and the CHANGELOG carries the user-visible note. The one
item this record closes is the review's "no `.specify/bugs/` folder" observation: the folder now
exists and follows the same shape as the two previous fixes.