# Bug Assessment: Subscriptions enter an infinite connect/disconnect loop

- **Slug**: subscription-content-length-zero
- **Created**: 2026-11-13
- **Source**: https://github.com/arrrrny/graphql_plus/issues/15
- **Verdict**: valid (mechanism differs from the issue title)
- **Severity**: high

## Report (verbatim or summarized)

> Subscriptions can enter an infinite loop between connect and disconnect against some cloud
> backends (reported on GCP Cloud Run), while working against a local backend and with other
> GraphQL subscription clients — pointing at the subscription HTTP handshake (content-length 0
> on the connect request) rather than the backend.
>
> **Problem**
> - Subscription connect requests break providers that reject `content-length: 0`
> - Infinite connect/disconnect loop makes subscriptions unusable on affected providers
> - Works locally, fails only on cloud environments, which makes it very hard for users to
>   diagnose

Mirrors `zino-hofmann/graphql-flutter#811` (open since Feb 2021, 15 comments). The upstream
thread's own maintainer reply points at `inactivityTimeout` / `autoReconnect` rather than at the
header, and one reporter's workaround is `inactivityTimeout: Duration(seconds: 0)`.

## Symptom

A subscription that is connected and healthy but receives no protocol-level keepalive is
force-closed after `inactivityTimeout` (default **30s**) and immediately reconnected, forever.
Each cycle is a full connect → `connection_init` → close, so no subscription ever delivers an
event and the client logs a repeating connect/disconnect pair. Nothing is wrong with the
network or the server — the connection is simply quiet.

## Reproduction

**The reported header theory does not reproduce on this SDK.** I captured the actual handshake
`dart:io` sends (`WebSocket.connect(uri, protocols:, headers:)`, the exact call in
`packages/graphql_plus/lib/src/utilities/platform_io.dart`) against a local `HttpServer`:

```
user-agent: Dart/3.14 (dart:io)
connection: Upgrade
cache-control: no-cache
accept-encoding: gzip
sec-websocket-version: 13
host: 127.0.0.1:59511
authorization: Bearer x
sec-websocket-extensions: permessage-deflate; client_max_window_bits
sec-websocket-key: HslJeblZZfF24ruC2am5fw==
sec-websocket-protocol: graphql-transport-ws
upgrade: websocket
```

No `content-length` header is sent — not `0`, not anything. So on Dart 3.14 the handshake is
not what breaks the provider. The loop is real, but it is produced by the keepalive watchdog.

To reproduce the loop:

1. `SocketClient(url, protocol: GraphQLProtocol.graphqlWs, config: SocketClientConfig(autoReconnect: true))` —
   `inactivityTimeout` defaults to 30s.
2. Point it at a server that completes the `graphql-ws` handshake but never sends a
   `ConnectionKeepAlive` (`{"type":"ka"}`) message. This is the normal case for Apollo Server 3+
   and NestJS.
3. After 30s the socket closes; `autoReconnect` reconnects; the cycle repeats indefinitely.

## Suspected Code Paths

- `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart:314-321` —
  `_disconnectOnKeepAliveTimeout`. `messages.whereType<ConnectionKeepAlive>().timeout(...,
  onTimeout: (e) { e.close(); _closeSocketChannel(); })`. The stream only emits when the *server*
  sends `ka`, so a server that never sends one hits the timeout unconditionally.
- `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart:49` —
  `inactivityTimeout` defaults to `Duration(seconds: 30)`.
- `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart:374-379` — the
  watchdog is armed for `graphql-ws`; `graphql-transport-ws` instead uses `_enqueuePing`.
- `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart:415-462` —
  `onConnectionLost` closes and reconnects; `_enqueuePing` restarts its timer on every `pong`.
- `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart:457-463` —
  `_enqueuePing` re-arms only on `pong`, so a server that ignores `ping` gets exactly one ping
  and then no further keepalive at all.

## Root Cause Hypothesis

For the legacy `graphql-ws` subprotocol, liveness is inferred from *server-initiated*
`ConnectionKeepAlive` messages. The watchdog closes the socket when no `ka` arrives within
`inactivityTimeout`. Many production servers never send `ka`, so a perfectly healthy but idle
subscription is declared dead every 30 seconds; `autoReconnect` then reconnects and the cycle
repeats. **Confidence: high** for the mechanism (the code path is unambiguous); the exact
"works locally, fails on cloud" split is not reproduced here and is likely a difference in which
subprotocol each backend negotiates or which server version is deployed.

The `graphql-transport-ws` path has a related but different defect: `_enqueuePing` is re-armed
only on receipt of `pong`, so a server that does not answer pings results in a single ping and
then permanent silence — no keepalive at all, and no disconnect loop.

## Proposed Remediation

**Preferred**: only arm the keepalive watchdog once the peer has actually demonstrated that it
sends keepalives.

Replace the unconditional `whereType<ConnectionKeepAlive>().timeout(...)` with a two-stage
watch: wait up to `inactivityTimeout` for the *first* `ConnectionKeepAlive`; if none arrives,
treat the connection as healthy (the peer simply does not use protocol keepalives) and do not
close. If one does arrive, arm the timeout on subsequent keepalives exactly as today. This
preserves dead-connection detection for servers that support it, and stops killing healthy idle
connections for servers that do not. No public API change.

**Alternatives**:

- **Make `inactivityTimeout` measure any inbound message, not just `ka`.** Correct for
  "is anything arriving at all", but it still closes a healthy subscription that is simply
  eventless — which is the common case for a subscription nobody is publishing to.
- **Default `inactivityTimeout` to null.** Removes the loop but silently drops the
  dead-connection detection that `graphql-ws` users may rely on; a behaviour change for every
  existing caller. Not preferred on `5.x`.

**Files likely to change**:

- `packages/graphql_plus/lib/src/links/websocket_link/websocket_client.dart`
- `packages/graphql_plus/test/websocket_test.dart`

**Tests to add or update**:

- A `graphql-ws` connection to a server that never sends `ka` stays open well past
  `inactivityTimeout` (the regression test).
- A `graphql-ws` connection to a server that does send `ka` still closes when the `ka` stream
  stops (the preserved behaviour).
- Document the `inactivityTimeout` / `autoReconnect` interaction, which the upstream thread shows
  is not discoverable.

## Risks & Considerations

- **Behaviour change for silent servers.** A connection to a server that never sends `ka` and
  then genuinely dies is no longer detected by the keepalive watchdog; it is detected by the
  socket close/error instead. That is the trade the issue asks for.
- **No API break.** Defaults and signatures are unchanged.
- **The issue title is misleading.** The `content-length: 0` theory is not reproducible on
  Dart 3.14; the assessment records what was actually measured rather than accepting the title.
- **`graphql-transport-ws` single-ping defect is separate.** It should be fixed in the same pass
  because it is the same `inactivityTimeout` misuse, but it is not the reported loop.

## Open Questions

- [NEEDS CLARIFICATION: which subprotocol the reporter's Cloud Run backend negotiated.] The fix
  is correct for either, but knowing it would confirm the mechanism end to end.