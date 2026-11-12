import 'dart:async';
import 'package:graphql_plus/graphql_plus.dart';

/// Simple header-based authentication link that adds [headerKey]: [getToken()] to every request.
///
/// If a lazy or exception-based authentication link is needed for your use case,
/// implementing your own from the [gql reference auth link] or opening an issue.
///
/// [gql reference auth link]: https://github.com/gql-dart/gql/blob/1884596904a411363165bcf3c7cfa9dcc2a61c26/examples/gql_example_http_auth_link/lib/http_auth_link.dart
class AuthLink extends Link {
  AuthLink({
    required this.getToken,
    this.headerKey = 'Authorization',
    this.onAuthError,
  });

  /// Authentication callback. Note – must include prefixes, e.g. `'Bearer $token'`
  final FutureOr<String?> Function() getToken;

  /// Header key to set to the result of [getToken]
  final String headerKey;

  /// Optional hook that enables refresh-and-replay.
  ///
  /// When an operation fails downstream and this is provided, it is called with the error. If
  /// it resolves to `true`, the token is fetched again through [getToken] and the *original*
  /// operation is re-sent once with the refreshed header. If it resolves to `false` (or is
  /// `null`), the error is re-thrown unchanged.
  ///
  /// A typical implementation checks for an expired-token signal, for example:
  ///
  /// ```dart
  /// AuthLink(
  ///   getToken: () => authStore.token,
  ///   onAuthError: (error) =>
  ///       error is HttpLinkServerException && error.response.statusCode == 401,
  /// )
  /// ```
  ///
  /// Only one replay is attempted: an operation that fails again after the refresh surfaces the
  /// second error rather than looping.
  final FutureOr<bool> Function(Object error)? onAuthError;

  /// Builds the request with the current token in [headerKey].
  static Future<Request> _withToken(
    Request request,
    String headerKey,
    FutureOr<String?> Function() getToken,
  ) async {
    final token = await getToken();
    return request.updateContextEntry<HttpLinkHeaders>(
      (headers) => HttpLinkHeaders(
        headers: <String, String>{
          ...headers?.headers ?? <String, String>{},
          if (token != null) headerKey: token,
        },
      ),
    );
  }

  @override
  Stream<Response> request(
    Request request, [
    NextLink? forward,
  ]) async* {
    final req = await _withToken(request, headerKey, getToken);
    final next = forward!;

    try {
      // Deliberately `await for` rather than `yield*`: inside an `async*` generator a
      // `yield*`-ed stream's error is forwarded to the listener instead of being thrown at
      // the `yield*`, so a surrounding try/catch never sees it and the replay below would be
      // dead code. See the "Auth refresh and replay" tests.
      await for (final response in next(req)) {
        yield response;
      }
    } catch (error) {
      if (onAuthError == null || !await onAuthError!(error)) {
        rethrow;
      }
      final retried = await _withToken(request, headerKey, getToken);
      await for (final response in next(retried)) {
        yield response;
      }
    }
  }
}
