# AppSync REALTIME subscriptions example

A runnable AWS AppSync (Amplify) subscriptions example for `graphql_plus`,
demonstrating [`AppSyncWebSocketLink`](../../packages/graphql_plus/lib/src/links/websocket_link/appsync_link.dart):

- queries and mutations go through `HttpLink` against the AppSync GraphQL endpoint,
- subscriptions are routed to `AppSyncWebSocketLink`, which speaks AppSync's
  REALTIME websocket protocol (connection authorization in the upgrade query
  string, per-message authorization on every start message, `connection_ack`
  handshake, `ka` keep-alives).

## Run it (API key mode)

```bash
APPSYNC_ENDPOINT=https://<id>.appsync-api.<region>.amazonaws.com/graphql \
APPSYNC_API_KEY=da2-… \
dart run bin/appsync_subscriptions.dart
```

The subscription document in `bin/appsync_subscriptions.dart` is an
`onCreateMessage` example — adjust it to your schema.

## Amplify / Cognito user pools

For an API authorized with a Cognito user pool (the common Amplify setup),
swap the auth provider — the callback is re-consulted on **every (re)connection
and subscription registration**, so a refreshed Cognito session JWT is always
what goes on the wire:

```dart
AppSyncWebSocketLink(
  endpoint,
  // e.g. with amazon_cognito_identity_dart_2, Amplify Flutter, or any
  // session store holding the current Cognito JWT:
  authProvider: AppSyncJwtAuth(() async => cognitoSession.jwtToken),
)
```

IAM-authorized APIs sign per message; hand `AppSyncIamAuth` a callback that
performs the SigV4 signing (the serialized operation is passed in) and returns
the signed authorization fields. See the `AppSyncAuthProvider` docs for the
exact signature targets.

## Reference

- AWS REALTIME protocol:
  https://docs.aws.amazon.com/appsync/latest/devguide/real-time-websocket-client.html
- The `graphql_plus` README's "AWS AppSync Support" section:
  https://github.com/arrrrny/graphql_plus#aws-appsync-support
- Upstream issue: https://github.com/zino-hofmann/graphql-flutter/issues/1163
