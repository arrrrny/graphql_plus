import 'dart:async';
import 'dart:convert';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../utilities/platform.dart';
import './websocket_link.dart';

/// Produces the AWS AppSync authorization fields for a connection or a
/// subscription registration.
///
/// The fields are merged with the AppSync GraphQL endpoint host into the
/// connection query-string `header` parameter and into
/// `payload.extensions.authorization` of every start message, per the
/// [AppSync REALTIME protocol](https://docs.aws.amazon.com/appsync/latest/devguide/real-time-websocket-client.html).
abstract class AppSyncAuthProvider {
  const AppSyncAuthProvider();

  /// Authorization fields for the websocket upgrade request.
  ///
  /// Invoked on every connection and reconnection attempt, so a dynamic
  /// token (for example a Cognito session JWT) can be refreshed between
  /// attempts.
  FutureOr<Map<String, String>> authorization();

  /// Authorization fields for one subscription registration.
  ///
  /// [serializedOperation] is the JSON string of the operation being
  /// registered — IAM signatures cover it, so it must be signed per message.
  ///
  /// The default re-uses [authorization]; override when the operation-level
  /// signature differs from the connection-level one.
  FutureOr<Map<String, String>> authorizationForOperation(
    String serializedOperation,
  ) =>
      authorization();
}

/// AppSync API key authorization (`x-api-key`).
class AppSyncApiKeyAuth extends AppSyncAuthProvider {
  const AppSyncApiKeyAuth(this.apiKey);

  /// The AppSync API key (`da2-…`).
  final String apiKey;

  @override
  Map<String, String> authorization() => <String, String>{
        'x-api-key': apiKey,
      };
}

/// AppSync JWT authorization for Cognito user pools, OIDC, and Lambda
/// authorizers (`Authorization` field).
///
/// [getToken] is invoked on every connection attempt and for every
/// subscription (re)registration, so it must return the *current* token —
/// read it from the session store rather than caching it here:
///
/// ```dart
/// AppSyncJwtAuth(() => cognitoStore.accessToken)
/// ```
class AppSyncJwtAuth extends AppSyncAuthProvider {
  const AppSyncJwtAuth(this.getToken);

  /// Returns the current JWT. May be asynchronous (a Cognito refresh).
  final FutureOr<String> Function() getToken;

  @override
  FutureOr<Map<String, String>> authorization() async =>
      <String, String>{'Authorization': await getToken()};
}

/// AppSync IAM authorization.
///
/// AppSync requires SigV4-signed fields per message, and the signature target
/// differs between the connection request (signed over
/// `POST https://<host>/graphql/connect` with body `"{}"`) and each
/// subscription registration (signed over `POST https://<host>/graphql` with
/// body = the JSON-stringified operation). [sign] receives the
/// serialized operation to sign, or `null` when signing the connection
/// request.
///
/// Perform the SigV4 signing with your AWS stack (for example an
/// AWS-computing-service endpoint or a local credential signer) and return
/// the ready authorization fields:
///
/// ```dart
/// AppSyncIamAuth((operation) async {
///   final signed = await signer.sign(
///     operation == null ? connectRequest : requestWithBody(operation),
///   );
///   return signed.fields; // host, x-amz-date, Authorization, …
/// });
/// ```
class AppSyncIamAuth extends AppSyncAuthProvider {
  const AppSyncIamAuth(this.sign);

  /// Signs one authorization request. [serializedOperation] is the
  /// JSON-stringified operation for a subscription registration, and `null`
  /// for the connection request.
  final FutureOr<Map<String, String>> Function(String? serializedOperation)
      sign;

  @override
  FutureOr<Map<String, String>> authorization() => sign(null);

  @override
  FutureOr<Map<String, String>> authorizationForOperation(
    String serializedOperation,
  ) =>
      sign(serializedOperation);
}

/// Serializes a [Request] into the AppSync REALTIME envelope.
///
/// The standard request body (`operationName`, `variables`, `query`) is
/// JSON-encoded into `payload.data` (a JSON string, per the protocol), and
/// the per-message authorization from [authProvider] is attached under
/// `payload.extensions.authorization`. Because the envelope may require a
/// freshly-resolved token, [serializeRequest] can return a [Future] — the
/// socket client awaits it before writing the start message.
///
/// Wire it through [AppSyncWebSocketLink]; passing it to a plain
/// [SocketClientConfig] requires `SocketClientConfig.serialize`.
class AppSyncRequestSerializer {
  const AppSyncRequestSerializer(this.authProvider, {required this.host});

  /// Supplies the per-message authorization fields.
  final AppSyncAuthProvider authProvider;

  /// Host of the AppSync GraphQL endpoint (not the realtime endpoint).
  final String host;

  /// AppSync REALTIME envelope for [request].
  FutureOr<Map<String, dynamic>> serializeRequest(Request request) async {
    final body = const RequestSerializer().serializeRequest(request);
    final data = jsonEncode(body);
    return <String, dynamic>{
      'data': data,
      'extensions': <String, dynamic>{
        'authorization': <String, String>{
          'host': host,
          ...await authProvider.authorizationForOperation(data),
        },
      },
    };
  }
}

/// Resolves the AppSync REALTIME websocket endpoint for a GraphQL endpoint.
///
/// - Standard AppSync domains
///   (`*.appsync-api.<region>.amazonaws.com`) become
///   `wss://*.appsync-realtime-api.<region>.amazonaws.com`, keeping the path.
/// - Custom domains keep the host and append `/realtime` to the path
///   (`https://api.example.com/graphql` →
///   `wss://api.example.com/graphql/realtime`).
/// - `http` maps to `ws` (useful against local mocks); `https` maps to `wss`.
String appSyncRealtimeEndpoint(String graphqlEndpoint) {
  final uri = Uri.parse(graphqlEndpoint);
  final scheme = uri.scheme == 'http' ? 'ws' : 'wss';
  if (uri.host.contains('appsync-api')) {
    return uri
        .replace(
          scheme: scheme,
          host: uri.host.replaceFirst('appsync-api', 'appsync-realtime-api'),
        )
        .toString();
  }
  final path =
      uri.path.endsWith('/') ? '${uri.path}realtime' : '${uri.path}/realtime';
  return uri.replace(scheme: scheme, path: path).toString();
}

/// A [WebSocketLink] pre-configured for AWS AppSync REALTIME subscriptions.
///
/// Queries and mutations keep going through an HTTP link against the GraphQL
/// endpoint; this link is meant for the subscription part of the client:
///
/// ```dart
/// final link = Link.split(
///   (request) => request.isSubscription,
///   AppSyncWebSocketLink(
///     'https://abc123.appsync-api.us-east-1.amazonaws.com/graphql',
///     authProvider: AppSyncJwtAuth(() => cognitoSession.jwtToken),
///   ),
///   httpLink,
/// );
/// ```
///
/// The link performs the REALTIME handshake (connection authorization in the
/// `header`/`payload` query parameters, bare `connection_init`, wait for
/// `connection_ack`), attaches per-message authorization to every start
/// message, and re-resolves both on every (re)connection — so dynamic
/// Cognito/OIDC tokens survive reconnects. See [AppSyncAuthProvider] for the
/// supported authorization modes (API key, JWT, IAM).
///
/// The websocket upgrade offers the `graphql-ws` subprotocol AppSync
/// expects; headers are not used, because the connection authorization
/// travels in the URL query parameters.
class AppSyncWebSocketLink extends WebSocketLink {
  factory AppSyncWebSocketLink(
    String endpoint, {
    required AppSyncAuthProvider authProvider,
    Duration? inactivityTimeout = const Duration(minutes: 5),
    bool autoReconnect = true,
    Duration delayBetweenReconnectionAttempts = const Duration(seconds: 5),
    Future<Duration?>? Function(int? code, String? reason)? onConnectionLost,
    Stream<ToggleConnectionState>? toggleConnection,
  }) {
    final host = Uri.parse(endpoint).host;
    return AppSyncWebSocketLink._(
      appSyncRealtimeEndpoint(endpoint),
      config: SocketClientConfig(
        serialize:
            AppSyncRequestSerializer(authProvider, host: host).serializeRequest,
        connectFn: (uri, protocols) => _connectWithConnectionAuth(
          uri,
          protocols,
          host: host,
          authProvider: authProvider,
        ),
        inactivityTimeout: inactivityTimeout,
        autoReconnect: autoReconnect,
        delayBetweenReconnectionAttempts: delayBetweenReconnectionAttempts,
        onConnectionLost: onConnectionLost,
        toggleConnection: toggleConnection,
      ),
    );
  }

  AppSyncWebSocketLink._(
    super.url, {
    required SocketClientConfig config,
  }) : super(config: config, subProtocol: AppSyncProtocol.realtime);

  /// Host of the AppSync GraphQL endpoint this link talks to.
  String get graphqlHost => Uri.parse(url).host.replaceFirst(
        'appsync-realtime-api',
        'appsync-api',
      );

  /// Builds the connection URI with the AppSync connection authorization in
  /// the `header`/`payload` query parameters, and connects.
  static Future<WebSocketChannel> _connectWithConnectionAuth(
    Uri uri,
    Iterable<String>? protocols, {
    required String host,
    required AppSyncAuthProvider authProvider,
  }) async {
    final authorization = await authProvider.authorization();
    final headerJson =
        jsonEncode(<String, String>{'host': host, ...authorization});
    final authedUri = uri.replace(queryParameters: <String, String>{
      ...uri.queryParameters,
      'header': base64.encode(utf8.encode(headerJson)),
      'payload': base64.encode(utf8.encode(jsonEncode(<String, dynamic>{}))),
    });
    return defaultConnectPlatform(authedUri, protocols);
  }
}
