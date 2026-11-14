// A runnable AWS AppSync REALTIME subscriptions example for graphql_plus.
//
// Queries and mutations go through HttpLink against the AppSync GraphQL
// endpoint; subscriptions are routed to AppSyncWebSocketLink, which speaks
// the AppSync REALTIME websocket protocol (connection authorization in the
// upgrade query string, per-message authorization on every start message).
//
// Run it against an API-key authorized AppSync API:
//
//   APPSYNC_ENDPOINT=https://<id>.appsync-api.<region>.amazonaws.com/graphql \
//   APPSYNC_API_KEY=da2-… \
//   dart run bin/appsync_subscriptions.dart
//
// For a Cognito user pool API, swap the auth provider (see `authProvider`
// below) — the token is re-resolved on every (re)connection and subscription
// registration, so a refreshed session JWT is always what goes on the wire.
import 'dart:async';
import 'dart:io';

import 'package:graphql_plus/graphql_plus.dart';

Future<void> main() async {
  final endpoint = Platform.environment['APPSYNC_ENDPOINT'];
  final apiKey = Platform.environment['APPSYNC_API_KEY'];
  if (endpoint == null || apiKey == null) {
    stderr.writeln(
      'Set APPSYNC_ENDPOINT and APPSYNC_API_KEY (see the file header or the README).',
    );
    exitCode = 2;
    return;
  }

  final subscription = r'''
    subscription onCreateMessage {
      onCreateMessage {
        __typename
        message
      }
    }
  ''';

  final client = GraphQLClient(
    link: Link.split(
      (request) => request.isSubscription,
      AppSyncWebSocketLink(
        endpoint,
        // API key mode. For Cognito user pools / OIDC / Lambda authorizers use
        // AppSyncJwtAuth(() async => cognitoSession.jwtToken) instead — it is
        // re-consulted on every (re)connection, so dynamic tokens survive
        // reconnects. For IAM, use AppSyncIamAuth(…) with your SigV4 signer.
        authProvider: AppSyncApiKeyAuth(apiKey),
        onConnectionLost: (code, reason) async {
          stdout
              .writeln('connection lost (code=$code): $reason — reconnecting');
          return const Duration(seconds: 1);
        },
      ),
      HttpLink(endpoint),
    ),
    cache: GraphQLCache(),
  );

  stdout.writeln('Subscribing to onCreateMessage on $endpoint …');
  final events = client.subscribe(
    SubscriptionOptions(
      document: gql(subscription),
    ),
  );

  await for (final snapshot in events) {
    if (snapshot.hasException) {
      stderr.writeln('subscription error: ${snapshot.exception}');
      continue;
    }
    stdout.writeln('event: ${snapshot.data}');
  }
}
