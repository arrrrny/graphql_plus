# Bug Assessment: A `graphql-transport-ws` peer that never answers `ping` loses its keepalive

- **Slug**: transport-ws-ping-keepalive
- **Created**: 2026-11-14
- **Source**: https://github.com/arrrrny/graphql_plus/pull/29 (review findings) · follow-up
  https://github.com/arrrrny/graphql_plus/issues/55
- **Verdict**: valid
- **Severity**: medium (3 minor findings, no data loss)

## Report (verbatim or summarized)

> Three minor findings on the review of #29, whose branch was gone after the squash merge, so
> the pipeline could not push a fixes round and the findings were orphaned. Tracked as
> https://github.com/arrrrny/graphql_plus/issues/55.

The three findings, in the review's own words:

1. **The `pong` re-arm is redundant, and it re-arms the periodic timer on every `pong`.** With
   `Timer.periodic` the timer re-arms itself, so the `pong` branch of the message listener no
   longer needs to call `_enqueuePing()` at all. The effect is that the interval is measured from
   the **last `pong`**, not from the last ping. For a peer that answers promptly the observable
   cadence is unchanged, which is why the suite stays green — but a peer that sends unsolicited
   or chatty `pong`s resets the timer faster than it can fire and the ping never goes out. That
   is a variant of the exact defect this PR fixes, reintroduced through a different door.
2. **Repeating pings with no `pong` deadline still cannot detect a dead peer.** Pings go out
   every `inactivityTimeout` forever, but no timer concludes that the *absence* of a `pong` means
   the peer is gone, so a half-open TCP connection stays `SocketConnectionState.connected`
   indefinitely, in-flight subscriptions never error and never reconnect. Pre-existing and not
   made worse by #29, but #29 is where the keepalive actually became functional, so it is the
   natural place to close it.
3. **The assertion does not pin what the test name claims.** `greaterThan(1)` passes if the
   client sends exactly two pings and then the timer dies — it would still pass against a fix
   that only got the keepalive half-working. A fixed `750ms` wall-clock wait is load-sensitive
   on a busy CI runner.

## Symptom

A `graphql-transport-ws` connection whose peer never answers `ping` received exactly one ping and
then nothing — the keepalive the config promises did not exist for the case it exists for. Two
follow-on defects made it worse than the missing repetition: a chatty `pong` could starve the
ping entirely, and nothing ever concluded the peer was dead.

## Reproduction

The keepalive tests in `packages/graphql_plus/test/websocket_test.dart` (group
`SocketClient graphql-transport-ws keepalive`) exercise all three behaviours against a throwaway
`HttpServer` on an ephemeral port:

- **Finding 1** — `keeps pinging a peer that chatters unsolicited pongs` starts a peer that
  answers every `ping` *and* chats `pong` every 20ms without being asked. With the re-arm
  reintroduced, the ping never reaches three; the fix's interval is measured from the connection.
- **Finding 2** — `closes the connection when a ping goes unanswered past the deadline` runs a
  peer that never answers. Without the deadline the connection stays `connected` and the test's
  `waitForCondition(() => closed)` never settles.
- **Finding 3** — the keepalive test awaits a third ping (`waitForCondition(() => pings >= 3)`)
  rather than sleeping a fixed wall-clock window and asserting `greaterThan(1)`, so a
  two-ping-then-dead timer cannot pass it.

## Assessment detail

Each finding was already fixed on `master` by a later merged PR before this record was written:

| Finding | Fixed by | What landed |
|---------|----------|-------------|
| 1 · pong re-arm | `91dfab2` "fix: address review comments on #29 (#36)" | `pong` branch cancels `_pongDeadline` only; no `_enqueuePing()` call. The interval belongs to the connection. |
| 2 · no pong deadline | `ead5ef8` "fix(ws): detect dead graphql-transport-ws peers with a pong deadline (#39)" (closes #35) | Every ping arms `_pongDeadline` at `inactivityTimeout ~/ 2`; expiry closes the socket channel; a `pong` cancels it. |
| 3 · weak assertion | `91dfab2` | The keepalive test awaits `pings >= 3`; a chatty-pong test was added; the `HttpServer` bootstrap was hoisted to one file-scope `startServer` helper. |

The CHANGELOG entry (`packages/graphql_plus/CHANGELOG.md`, `## Fixed`) covers the keepalive fix
and its scope note; #35 records the deadline gap that #39 closed.

## Verification of the fixes (this record)

`dart analyze --fatal-infos` → `No issues found!` and `dart test -j 2` → 254/254 passing on
`master` at `4859a1c`.

Mutation testing was run to prove the tests genuinely pin each fix — reverting each fix in turn
and confirming the suite goes red:

| Mutation | Test that must fail | Result |
|----------|--------------------|--------|
| Re-add `_enqueuePing()` to the `pong` branch (finding 1) | `keeps pinging a peer that chatters unsolicited pongs` | **fails** — ping starves, as the finding predicts |
| Remove the `_pongDeadline = Timer(...)` arm (finding 2) | `closes the connection when a ping goes unanswered past the deadline` | **fails** — connection never closes |

Both mutations were reverted; the tree is byte-identical to `master`.