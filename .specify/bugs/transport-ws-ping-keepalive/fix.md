# Bug Fix: A `graphql-transport-ws` peer that never answers `ping` loses its keepalive

- **Slug**: transport-ws-ping-keepalive
- **Fixed**: 2026-11-14
- **Assessment**: ./assessment.md
- **Status**: applied (on `master` before this record)

## Summary

No code change was needed in this round: the three findings from the review of #29 were already
fixed on `master` by later merged PRs before this record was written. What follows is the fix as
it stands on `master`, with the commit that landed it, plus the mutation evidence that the tests
pin each behaviour. The one deliverable of this round is this `.specify/bugs/` record — the
review's own "not inline-able" note asked for it, and it is the pattern the previous two fixes
followed.

## Changes

| File | Change | Notes |
|------|--------|-------|
| `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart` | `_enqueuePing` uses `Timer.periodic` instead of a one-shot `Timer` | landed in `91dfab2`; the ping no longer depends on being acknowledged |
| same | the `pong` branch cancels `_pongDeadline` and does **not** call `_enqueuePing()` | landed in `91dfab2`; the cadence belongs to the connection, not to the last `pong` |
| same | every ping arms `_pongDeadline = Timer(inactivityTimeout ~/ 2, …)`; a `pong` cancels it; expiry closes the socket channel | landed in `ead5ef8` (closes #35); detects a half-open TCP connection |
| same | `_pongDeadline` / `_pingTimer` cancelled in `onConnectionLost` and `dispose` | landed in `91dfab2` / `ead5ef8` |
| `packages/graphql_plus/test/websocket_test.dart` | keepalive test awaits `pings >= 3`; chatty-pong test added; `startServer` hoisted to file scope | landed in `91dfab2` |
| `packages/graphql_plus/CHANGELOG.md` | `## Fixed` entry for the keepalive, with the scope note pointing at #35 | landed in `91dfab2` |

## Why the deadline is half the ping interval

`_pongDeadline` is measured from the last ping and must be strictly less than the ping interval:
`inactivityTimeout` is the same value as the interval, so a full-length deadline would be
cancelled by the next ping tick before it could fire. Half the interval leaves the deadline a
chance to conclude the peer is gone while still giving a slow-but-alive peer room to answer.

## What this record adds beyond the code

The assessment's "Reproduction" section records how each of the three findings is exercised, and
the fix record carries the mutation evidence: re-adding the `pong` re-arm makes the chatty-pong
test fail, and removing the deadline arm makes the unanswered-ping test fail. Both mutations were
reverted; the tree is byte-identical to `master`.