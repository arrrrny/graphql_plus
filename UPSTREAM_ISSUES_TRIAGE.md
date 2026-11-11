# Upstream Issues Triage — zino-hofmann/graphql-flutter open issues

Generated from the GitHub API on 2026-11-11 while forking `graphql` -> `graphql_plus`
(`packages/graphql_plus`, Dart client) and `graphql_flutter` -> `graphql_flutter_plus`
(`packages/graphql_flutter_plus`, Flutter widgets layer). Upstream has declared
[Maintenance status: Low](https://github.com/zino-hofmann/graphql-flutter/issues/763); the highest-impact issues
are mirrored here with links so the original reporters are notified and can follow the fixes.

---

## Fork status vs upstream

| Area | Upstream | This fork |
| --- | --- | --- |
| Dart client (`graphql`) | latest published 5.2.4 | **`graphql_plus` 5.2.5 published** — 5.2.4 + QueryManager timeout/completer hardening + operation cancellation |
| Flutter widgets (`graphql_flutter`) | latest published **5.3.0** on pub.dev (upstream #1527's "not published" is outdated) | **`graphql_flutter_plus` 5.3.1** — the 5.3.0 widgets layer rebuilt on `graphql_plus` ^5.2.5 |

---

## 🔄 Mirrored issues (upstream reporter notification path)

| This fork | Upstream | Title |
| --- | --- | --- |
| [#11](https://github.com/arrrrny/graphql_plus/issues/11) | [upstream #201](https://github.com/zino-hofmann/graphql-flutter/issues/201) | Offline mutation queue |
| [#8](https://github.com/arrrrny/graphql_plus/issues/8) | [upstream #220](https://github.com/zino-hofmann/graphql-flutter/issues/220) | [Auth] How to re-request an operation with new context? |
| [#10](https://github.com/arrrrny/graphql_plus/issues/10) | [upstream #333](https://github.com/zino-hofmann/graphql-flutter/issues/333) | refetchQueries option for client.mutate |
| [#12](https://github.com/arrrrny/graphql_plus/issues/12) | [upstream #354](https://github.com/zino-hofmann/graphql-flutter/issues/354) | Cache invalidation/deletion options |
| [#9](https://github.com/arrrrny/graphql_plus/issues/9) | [upstream #424](https://github.com/zino-hofmann/graphql-flutter/issues/424) | Isolate the GraphClient in another thread |
| [#1](https://github.com/arrrrny/graphql_plus/issues/1) | [upstream #543](https://github.com/zino-hofmann/graphql-flutter/issues/543) | Query never ends if network gets disconnected |
| [#7](https://github.com/arrrrny/graphql_plus/issues/7) | [upstream #592](https://github.com/zino-hofmann/graphql-flutter/issues/592) | Better cookie-based authentication support |
| [#13](https://github.com/arrrrny/graphql_plus/issues/13) | [upstream #712](https://github.com/zino-hofmann/graphql-flutter/issues/712) | Consider moving to dio over http client |
| [#15](https://github.com/arrrrny/graphql_plus/issues/15) | [upstream #811](https://github.com/zino-hofmann/graphql-flutter/issues/811) | [subscriptions] http sets content-length = 0  breaking some providers i.e. google cloud run |
| [#5](https://github.com/arrrrny/graphql_plus/issues/5) | [upstream #851](https://github.com/zino-hofmann/graphql-flutter/issues/851) | Client.mutate - optimisticResult? |
| [#4](https://github.com/arrrrny/graphql_plus/issues/4) | [upstream #877](https://github.com/zino-hofmann/graphql-flutter/issues/877) | None GraphQL server error message not part of Exception |
| [#3](https://github.com/arrrrny/graphql_plus/issues/3) | [upstream #1118](https://github.com/zino-hofmann/graphql-flutter/issues/1118) | Null fields being written to cache for partial object (overwriting existing fields) |
| [#16](https://github.com/arrrrny/graphql_plus/issues/16) | [upstream #1163](https://github.com/zino-hofmann/graphql-flutter/issues/1163) | Amplify Subscriptions support |
| [#6](https://github.com/arrrrny/graphql_plus/issues/6) | [upstream #1188](https://github.com/zino-hofmann/graphql-flutter/issues/1188) | Detect when subscription is lost |
| [#14](https://github.com/arrrrny/graphql_plus/issues/14) | [upstream #1323](https://github.com/zino-hofmann/graphql-flutter/issues/1323) | There is no way to refresh AUTH token on socket reconnect |
| [#2](https://github.com/arrrrny/graphql_plus/issues/2) | [upstream #1457](https://github.com/zino-hofmann/graphql-flutter/issues/1457) | Timeout should be handled by the http client not the library |

---

## ⏱ Timeout/completer cluster — likely already fixed by `graphql_plus` 5.2.5

The `QueryManager` timeout/completer hardening shipped in `graphql_plus` 5.2.5 targets exactly this cluster.
Verify each against the fixed code and close the corresponding fork issue with the fix commit reference:

- [#1453](https://github.com/zino-hofmann/graphql-flutter/issues/1453) — Hi all, this line will break all requests that take longer than 5 seconds without any warning ...can this be a configuration value?
- [#1470](https://github.com/zino-hofmann/graphql-flutter/issues/1470) — Timeout is reseting to default after calling copyWith method of graphql client on graphql 5.2.0-beta.9
- [#1494](https://github.com/zino-hofmann/graphql-flutter/issues/1494) — queryRequestTimeout doesn't immediately terminate request on timeout.
- [#1535](https://github.com/zino-hofmann/graphql-flutter/issues/1535) — graphql v5.2.4, QueryManager, guard Completer.complete() against timeout/error race

---

## Timeout/completer cluster (4)

- [#1453](https://github.com/zino-hofmann/graphql-flutter/issues/1453) — Hi all, this line will break all requests that take longer than 5 seconds without any warning ...can this be a configuration value?
- [#1535](https://github.com/zino-hofmann/graphql-flutter/issues/1535) — graphql v5.2.4, QueryManager, guard Completer.complete() against timeout/error race
- [#1470](https://github.com/zino-hofmann/graphql-flutter/issues/1470) — Timeout is reseting to default after calling copyWith method of graphql client on graphql 5.2.0-beta.9
- [#1494](https://github.com/zino-hofmann/graphql-flutter/issues/1494) — queryRequestTimeout doesn't immediately terminate request on timeout.

## WebSocket & subscriptions (47)

- [#1513](https://github.com/zino-hofmann/graphql-flutter/issues/1513) — 🚀 Revamping `graphql_flutter`: Roadmap, Community Involvement & Long-Term Maintenance
- [#655](https://github.com/zino-hofmann/graphql-flutter/issues/655) — Allowing access to ConnectionState from GraphQLClient for Subscriptions
- [#860](https://github.com/zino-hofmann/graphql-flutter/issues/860) — Subscription not rec-connecting
- [#1456](https://github.com/zino-hofmann/graphql-flutter/issues/1456) — CLOSE SUBSCRIPTION
- [#916](https://github.com/zino-hofmann/graphql-flutter/issues/916) — Subscription error - start received before the connection is initialised
- [#1278](https://github.com/zino-hofmann/graphql-flutter/issues/1278) — How to dispose subscription request?
- [#1415](https://github.com/zino-hofmann/graphql-flutter/issues/1415) — Make `connectivity_plus` optional.
- [#1321](https://github.com/zino-hofmann/graphql-flutter/issues/1321) — Websocket not reconnect when no internet
- [#934](https://github.com/zino-hofmann/graphql-flutter/issues/934) — Subscription Authorization error because of not waiting for connection_ack after connection_init
- [#986](https://github.com/zino-hofmann/graphql-flutter/issues/986) — Make the final Request object available in Response.context
- [#1352](https://github.com/zino-hofmann/graphql-flutter/issues/1352) — Support of Multipart HTTP Protocol for GraphQL Subscriptions
- [#1379](https://github.com/zino-hofmann/graphql-flutter/issues/1379) — Null check operator used on a null value in SocketClient.onConnectionLost
- [#1318](https://github.com/zino-hofmann/graphql-flutter/issues/1318) — The returned information is incomplete/missing.
- [#1298](https://github.com/zino-hofmann/graphql-flutter/issues/1298) — SocketClient (WebSocket links): Pluggable retry strategy
- [#1259](https://github.com/zino-hofmann/graphql-flutter/issues/1259) — ValueStreamError: ValueStream has no value.
- [#1426](https://github.com/zino-hofmann/graphql-flutter/issues/1426) — [WebsocketClient] onConnectionLost() not called when autoRecconect is false
- [#572](https://github.com/zino-hofmann/graphql-flutter/issues/572) — How to know that web socket is connected in subscription widget.
- [#1211](https://github.com/zino-hofmann/graphql-flutter/issues/1211) — Subscription doesn't disconnect from the server when you stop listening to the stream.
- [#1004](https://github.com/zino-hofmann/graphql-flutter/issues/1004) — [Feature Request] onStreamError in WebSocketLink
- [#1255](https://github.com/zino-hofmann/graphql-flutter/issues/1255) — Need example how to combine query and subscription in one widget (documentation improvement)
- [#741](https://github.com/zino-hofmann/graphql-flutter/issues/741) — Improve Documentation
- [#1253](https://github.com/zino-hofmann/graphql-flutter/issues/1253) — Websocket connection does not reconnect after WebSocketChannelException
- [#1356](https://github.com/zino-hofmann/graphql-flutter/issues/1356) — Log polling WatchQuery request/response individual duration
- [#1420](https://github.com/zino-hofmann/graphql-flutter/issues/1420) — WebSocketException: Connection to 'http://*************************#' was not upgraded to websocket
- [#550](https://github.com/zino-hofmann/graphql-flutter/issues/550) — Subscriptions never connect to Amplify mock server
- [#868](https://github.com/zino-hofmann/graphql-flutter/issues/868) — Add subscription pusher example to docs
- [#1277](https://github.com/zino-hofmann/graphql-flutter/issues/1277) — After connectOrReconnect the Initialising connection starts but subscription is not listening to new subscription result.
- [#1335](https://github.com/zino-hofmann/graphql-flutter/issues/1335) — OptimisticResult problem
- [#329](https://github.com/zino-hofmann/graphql-flutter/issues/329) — How to wait for connection acknowledgement and then start subscription.
- [#791](https://github.com/zino-hofmann/graphql-flutter/issues/791) — [QUESTION] Why is GraphQLProvider dependent on ValueNotifier<GraphQLClient>
- [#1026](https://github.com/zino-hofmann/graphql-flutter/issues/1026) —  Adding custom header test, this required to change a little bit the mock server
- [#1252](https://github.com/zino-hofmann/graphql-flutter/issues/1252) — Question: can subscription be updated with client.writeQuery?
- [#1270](https://github.com/zino-hofmann/graphql-flutter/issues/1270) — ws: Unhandled exceptions from SocketClient
- [#1271](https://github.com/zino-hofmann/graphql-flutter/issues/1271) — Custom connectFn - WebSocketChannel Socket<List<int>> 
- [#1395](https://github.com/zino-hofmann/graphql-flutter/issues/1395) — Subscription throws uncaught handshake exception when using http
- [#1477](https://github.com/zino-hofmann/graphql-flutter/issues/1477) — useSubscription / SubscriptionWidget / client.subscribe
- [#1495](https://github.com/zino-hofmann/graphql-flutter/issues/1495) — Cannot reconnect subscription on Windows after night hibernation
- [#989](https://github.com/zino-hofmann/graphql-flutter/issues/989) — Subscription will receive same event in some edge case
- [#1263](https://github.com/zino-hofmann/graphql-flutter/issues/1263) — improve melos configuration
- [#1313](https://github.com/zino-hofmann/graphql-flutter/issues/1313) — Subscription callback onSubscriptionResult not called
- [#1349](https://github.com/zino-hofmann/graphql-flutter/issues/1349) — example of subscription implementation
- [#1417](https://github.com/zino-hofmann/graphql-flutter/issues/1417) — Failed to lookup host on all versions error
- [#1444](https://github.com/zino-hofmann/graphql-flutter/issues/1444) — Can we use websocketlink for data transmission 
- [#1488](https://github.com/zino-hofmann/graphql-flutter/issues/1488) — Graphql typename "Subscription" makes the results duplicated
- [#1503](https://github.com/zino-hofmann/graphql-flutter/issues/1503) — dart:io Platform is not available in Flutter web.
- [#1519](https://github.com/zino-hofmann/graphql-flutter/issues/1519) — Please docoment when exactly onConnectionLost is called for subscriptions
- [#1524](https://github.com/zino-hofmann/graphql-flutter/issues/1524) — Unconditional `print()`

## Cache & normalization (30)

- [#340](https://github.com/zino-hofmann/graphql-flutter/issues/340) — Provide a way to control cache ttl
- [#1287](https://github.com/zino-hofmann/graphql-flutter/issues/1287) — Support isar store
- [#1151](https://github.com/zino-hofmann/graphql-flutter/issues/1151) — How to use Hive.lazyBox
- [#1130](https://github.com/zino-hofmann/graphql-flutter/issues/1130) — It seems that `networkOnly` queries can return a `cache` result before the actual `network` result
- [#1479](https://github.com/zino-hofmann/graphql-flutter/issues/1479) — Network First Cache FetchPolicy Request
- [#1227](https://github.com/zino-hofmann/graphql-flutter/issues/1227) — Allow fragments to listen to rebroadcast
- [#753](https://github.com/zino-hofmann/graphql-flutter/issues/753) — Consider caching errors
- [#928](https://github.com/zino-hofmann/graphql-flutter/issues/928) — Allow fetchPolicy of cacheFirst in fetchMore
- [#1389](https://github.com/zino-hofmann/graphql-flutter/issues/1389) — How to return partial data from cache?
- [#1498](https://github.com/zino-hofmann/graphql-flutter/issues/1498) — Request for non-hive cache implementation
- [#941](https://github.com/zino-hofmann/graphql-flutter/issues/941) — Cache Population issue
- [#1256](https://github.com/zino-hofmann/graphql-flutter/issues/1256) — How to setup Proxy in GraphQL
- [#1516](https://github.com/zino-hofmann/graphql-flutter/issues/1516) — Query is returned with incorret values in one field.
- [#643](https://github.com/zino-hofmann/graphql-flutter/issues/643) — Exception in onCompleted silently fails other functions
- [#652](https://github.com/zino-hofmann/graphql-flutter/issues/652) — Consider fetch policy link, cache interface link 
- [#1378](https://github.com/zino-hofmann/graphql-flutter/issues/1378) — Does the package support connection relay for pagination?
- [#1402](https://github.com/zino-hofmann/graphql-flutter/issues/1402) — Example needed for cache
- [#792](https://github.com/zino-hofmann/graphql-flutter/issues/792) — Unclear error when attempting to mutate with FetchPolicy.cacheOnly
- [#1302](https://github.com/zino-hofmann/graphql-flutter/issues/1302) — Errors out when useGETForQueries is enabled in HTTPLink
- [#1373](https://github.com/zino-hofmann/graphql-flutter/issues/1373) — retry request when token invalid or expired occured
- [#1390](https://github.com/zino-hofmann/graphql-flutter/issues/1390) — Typo in packages/graphql/lib/src/core/policies.dart
- [#1411](https://github.com/zino-hofmann/graphql-flutter/issues/1411) — GraphQLDataProxy usage example fails with PartialDataException(path: __typename)
- [#650](https://github.com/zino-hofmann/graphql-flutter/issues/650) — [future] data-level cache-source
- [#824](https://github.com/zino-hofmann/graphql-flutter/issues/824) — Consider making pollInterval work with cacheFirst
- [#841](https://github.com/zino-hofmann/graphql-flutter/issues/841) — Not all of QueryOptions valid/sensible arguments to query, which causes confusion
- [#842](https://github.com/zino-hofmann/graphql-flutter/issues/842) — Test watchQuery/ObservableQuery thoroughly
- [#1381](https://github.com/zino-hofmann/graphql-flutter/issues/1381) — [BUG] writeFragment on interface fields causes an incorrect change in __typename
- [#1412](https://github.com/zino-hofmann/graphql-flutter/issues/1412) — OperationException thrown  from a WatchQuery operation 
- [#1459](https://github.com/zino-hofmann/graphql-flutter/issues/1459) — Should CacheProvider still be used?
- [#1512](https://github.com/zino-hofmann/graphql-flutter/issues/1512) — Stale network responses for previous variables are emitted when updating watchQuery variables in combination with FetchPolicy.cacheAndNetwork

## Auth & network (7)

- [#494](https://github.com/zino-hofmann/graphql-flutter/issues/494) — Pass NextLink to retry request with ErrorLink
- [#615](https://github.com/zino-hofmann/graphql-flutter/issues/615) — Distinguish No internet connection from "unauthorized" etc.
- [#1443](https://github.com/zino-hofmann/graphql-flutter/issues/1443) — Update GraphqlClient Link  after initialization💫
- [#1405](https://github.com/zino-hofmann/graphql-flutter/issues/1405) — Connection closed before full header was recieved error
- [#1472](https://github.com/zino-hofmann/graphql-flutter/issues/1472) — Doubt regarding graphql client
- [#1383](https://github.com/zino-hofmann/graphql-flutter/issues/1383) — Issue with Registering Users via GraphQL on Supabase - Need Assistance
- [#1442](https://github.com/zino-hofmann/graphql-flutter/issues/1442) — QueryWidget still makes query request when is not rendered anymore

## Bug reports (unmirrored) (0)


## Feature requests (24)

- [#862](https://github.com/zino-hofmann/graphql-flutter/issues/862) — Example tests/reference implementations
- [#513](https://github.com/zino-hofmann/graphql-flutter/issues/513) — Is there a way to use query batching?
- [#571](https://github.com/zino-hofmann/graphql-flutter/issues/571) — Callback to runQuery or LazyQuery
- [#392](https://github.com/zino-hofmann/graphql-flutter/issues/392) — fetchMore error handling
- [#1372](https://github.com/zino-hofmann/graphql-flutter/issues/1372) — Relay-style `useFragment` hook
- [#1173](https://github.com/zino-hofmann/graphql-flutter/issues/1173) — Does it still support Apollo Automatic Persisted Queries
- [#1509](https://github.com/zino-hofmann/graphql-flutter/issues/1509) — Should ObservableQuery.refetch() return non-nullable result?
- [#603](https://github.com/zino-hofmann/graphql-flutter/issues/603) — [Feature request] NetworkStatus enum in result
- [#1155](https://github.com/zino-hofmann/graphql-flutter/issues/1155) — Unable to run Starwars example on MacOs
- [#636](https://github.com/zino-hofmann/graphql-flutter/issues/636) — Optionally typed API
- [#1124](https://github.com/zino-hofmann/graphql-flutter/issues/1124) — ws: enfoce the recreation of the client and disallow the method call `connectOrReconnect`
- [#1123](https://github.com/zino-hofmann/graphql-flutter/issues/1123) — ws: abstract the implementation with a patter to avoid the chain of if else
- [#1154](https://github.com/zino-hofmann/graphql-flutter/issues/1154) — Freezed like `copyWith` method for `WatchQueryOptions`
- [#1351](https://github.com/zino-hofmann/graphql-flutter/issues/1351) — Reactive Variable Support Like Apollo Client 3
- [#1497](https://github.com/zino-hofmann/graphql-flutter/issues/1497) — Support for Upload Progress Tracking with Multipart Requests
- [#798](https://github.com/zino-hofmann/graphql-flutter/issues/798) — [refactor/redesign] decouple ObservableQuery's mutation and query logic
- [#1043](https://github.com/zino-hofmann/graphql-flutter/issues/1043) — Improve test coverage
- [#1101](https://github.com/zino-hofmann/graphql-flutter/issues/1101) — Validate commit messages in CI
- [#1126](https://github.com/zino-hofmann/graphql-flutter/issues/1126) — ws: create client with a future
- [#1172](https://github.com/zino-hofmann/graphql-flutter/issues/1172) — Throw custom errors from a specific link (ErrorLink)
- [#1430](https://github.com/zino-hofmann/graphql-flutter/issues/1430) — Invalid GraphQL request, extensions: {details: payload too large, code: INVALID_GRAPHQL_REQUEST}}]}))
- [#1465](https://github.com/zino-hofmann/graphql-flutter/issues/1465) — Any example on how to use the parser?
- [#1476](https://github.com/zino-hofmann/graphql-flutter/issues/1476) — Take operation name from document string when QueryOptions.operationName is not specified
- [#1482](https://github.com/zino-hofmann/graphql-flutter/issues/1482) — Create shorthand isRefetching for QueryResults

## Questions / QA (2)

- [#1125](https://github.com/zino-hofmann/graphql-flutter/issues/1125) — ws: add integration testing to support the new ws protocol
- [#1384](https://github.com/zino-hofmann/graphql-flutter/issues/1384) — Executing the same query in parallel only makes one request

## Maintenance / meta (29)

- [#477](https://github.com/zino-hofmann/graphql-flutter/issues/477) — Use sdk version constraints to better manage api changes
- [#634](https://github.com/zino-hofmann/graphql-flutter/issues/634) — Gracefully handle flutter navigation
- [#1501](https://github.com/zino-hofmann/graphql-flutter/issues/1501) — Does making `maybeRebroadcastQueries` `async` introduce any sort of race condition? I could have sworn I tried this back in the day and ran into issues where the state in the app was incorrect because `maybeRebroadcastQueries` was no longer synchronous / executed serially. And that added to the fact that the equality function itself was not async so it still took up the 150ms of time (just deferred which allowed flutter to optimize slightly). I may be mistaken. But if that is the case, you could still have it be async and throw it into a queue.
- [#802](https://github.com/zino-hofmann/graphql-flutter/issues/802) — Support @defer directive
- [#1149](https://github.com/zino-hofmann/graphql-flutter/issues/1149) — docs: add more info about link support like dio
- [#1471](https://github.com/zino-hofmann/graphql-flutter/issues/1471) — Queries timing out on device first/cold boot
- [#1530](https://github.com/zino-hofmann/graphql-flutter/issues/1530) — Graphql urlencode
- [#1293](https://github.com/zino-hofmann/graphql-flutter/issues/1293) — Exception but with Response Data , OperationException
- [#1106](https://github.com/zino-hofmann/graphql-flutter/issues/1106) — investigate the motivation of not null safety on graphql_flutter in pub.dev
- [#518](https://github.com/zino-hofmann/graphql-flutter/issues/518) — [starwars example] pin graphql_starwars_test_server dependency to 0.0.5 
- [#855](https://github.com/zino-hofmann/graphql-flutter/issues/855) — Example on using pollInterval query
- [#828](https://github.com/zino-hofmann/graphql-flutter/issues/828) — move to .env for examples
- [#1337](https://github.com/zino-hofmann/graphql-flutter/issues/1337) — How does ResultsAccumulator handle uniqueness?
- [#1360](https://github.com/zino-hofmann/graphql-flutter/issues/1360) — It does not seem that you are canceling timer on `stopPolling` operation.
- [#1370](https://github.com/zino-hofmann/graphql-flutter/issues/1370) — OperationException(linkException: ResponseFormatException(originalException: type 'Null' is not a subtype of type 'String' in type cast
- [#576](https://github.com/zino-hofmann/graphql-flutter/issues/576) — HTTP redirect to HTTPS
- [#1403](https://github.com/zino-hofmann/graphql-flutter/issues/1403) — Documentation not clear about uploading file
- [#1023](https://github.com/zino-hofmann/graphql-flutter/issues/1023) — doc: improve the documentation regarding the new parse function
- [#1266](https://github.com/zino-hofmann/graphql-flutter/issues/1266) — reintroduce different flutter channel inside the ci
- [#1291](https://github.com/zino-hofmann/graphql-flutter/issues/1291) — MutationOptions type + flutter type
- [#1345](https://github.com/zino-hofmann/graphql-flutter/issues/1345) — How can we set parameter to non-final in graphQL auto-generated response? 
- [#1359](https://github.com/zino-hofmann/graphql-flutter/issues/1359) — No getting response in WhenData
- [#1396](https://github.com/zino-hofmann/graphql-flutter/issues/1396) — Extreme slowness/jank with JSON scalar
- [#1408](https://github.com/zino-hofmann/graphql-flutter/issues/1408) — Not able to Mock the Result of Query Widget
- [#1439](https://github.com/zino-hofmann/graphql-flutter/issues/1439) — Using the latest version of the graphql package not updating the connectivity_plus package in pods
- [#1440](https://github.com/zino-hofmann/graphql-flutter/issues/1440) — HttpLinkParserException (ResponseFormatException(originalException: type 'List<dynamic>' is not a subtype of type 'String' in type cast, originalStackTrace: #0 
- [#1481](https://github.com/zino-hofmann/graphql-flutter/issues/1481) — Issue with Retrieving Cart Values and Incorrect Input Type in addLineItemsToCart – Shopify Flutter
- [#1527](https://github.com/zino-hofmann/graphql-flutter/issues/1527) — v5.3.0 not published to pub.dev
- [#1528](https://github.com/zino-hofmann/graphql-flutter/issues/1528) — **Medium (non-blocking):** Flaky under parallel load — this test fails intermittently in the full suite (the non-cancelled request assertion at `:419` gets `hasException == true`), but passes 3/3 in isolation.

---

## Summary

| Bucket | Count | Status |
| --- | --- | --- |
| Mirrored | 16 | mirrored with links above |
| Timeout/completer cluster | 4 | likely fixed by graphql_plus 5.2.5 — verify & close |
| WebSocket & subscriptions | 47 | open for triage / implementation |
| Cache & normalization | 30 | open for triage / implementation |
| Auth & network | 7 | open for triage / implementation |
| Bug reports (unmirrored) | 0 | open for triage / implementation |
| Feature requests | 24 | open for triage / implementation |
| Questions / QA | 2 | open for triage / implementation |
| Maintenance / meta | 29 | open for triage / implementation |
| **Total open upstream issues** | **159** |  |

Highest-signal next candidates for mirroring or direct implementation: pick the top of
`Bug reports (unmirrored)` and `Feature requests` by reaction count. The fork is master-first:
all work branches cut from `master`.

