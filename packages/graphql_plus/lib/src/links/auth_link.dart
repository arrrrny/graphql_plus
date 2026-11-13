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
  ///
  /// This is called once per request, and once more for a refresh-and-replay. It must be
  /// **idempotent and cheap**: concurrent 401s share a single in-flight refresh (see
  /// [_refreshing]), but a callback that mints a *different* token on every call will still
  /// hand a different value to each replay. Prefer reading an already-refreshed value (for
  /// example `() => authStore.token`) over performing the refresh inside this callback.
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
  /// second error rather than looping. If the consumer cancels its subscription while the
  /// refresh or the replay is in flight, no replay is sent and no further events are emitted.
  final FutureOr<bool> Function(Object error)? onAuthError;

  /// Builds the request with the current token in [headerKey].
  static Future<Request> _withToken(
    Request request,
    String headerKey,
    FutureOr<String?> Function() getToken,
  ) async {
    final token = await getToken();
    return _applyToken(request, headerKey, token);
  }

  /// Returns [request] with [token] written to [headerKey], without fetching it.
  static Request _applyToken(
    Request request,
    String headerKey,
    String? token,
  ) =>
      request.updateContextEntry<HttpLinkHeaders>(
        (headers) => HttpLinkHeaders(
          headers: <String, String>{
            ...headers?.headers ?? <String, String>{},
            if (token != null) headerKey: token,
          },
        ),
      );

  /// The single in-flight refresh shared by every operation that hits a 401 at the same time.
  ///
  /// Without this, N parallel requests that all observe an expired token each call [getToken]
  /// once, so a caller that rotates tokens per call would hand out N different "fresh" tokens
  /// for one refresh. The future resolves to the refreshed token; every concurrent caller
  /// receives the same value.
  Future<String?>? _refreshing;

  Future<String?> _refresh() {
    final existing = _refreshing;
    if (existing != null) return existing;
    final future = Future<String?>.sync(getToken);
    _refreshing = future;
    future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
    return future;
  }

  @override
  Stream<Response> request(
    Request request, [
    NextLink? forward,
  ]) {
    final next = forward!;
    return Stream<Response>.multi((controller) {
      StreamSubscription<Response>? forwardSub;
      var cancelled = false;
      var replaying = false;

      Future<void> refreshAndReplay(
        Object originalError,
        StackTrace originalStack,
      ) async {
        replaying = true;
        try {
          final refreshedToken = await _refresh();
          if (cancelled) return;
          // Reuse the token the shared refresh produced rather than calling getToken again:
          // a caller that rotates tokens per call must not hand a second value to the replay.
          final retried = _applyToken(request, headerKey, refreshedToken);
          if (cancelled) return;

          await for (final response in next(retried)) {
            if (cancelled) break;
            controller.add(response);
          }
          if (!cancelled) await controller.close();
        } catch (_) {
          // The replay itself failed. Surface the *original* error: it is the one the caller
          // cares about, and a failure while refreshing must not mask it.
          if (!cancelled) controller.addError(originalError, originalStack);
        }
      }

      Future<void> run() async {
        try {
          final req = await _withToken(request, headerKey, getToken);
          if (cancelled) return;
          forwardSub = next(req).listen(
            controller.add,
            onError: (Object error, StackTrace stack) async {
              // Not an auth failure, or the caller declined a refresh: surface it unchanged.
              if (replaying || cancelled || onAuthError == null) {
                if (!cancelled) controller.addError(error, stack);
                return;
              }
              final refresh = await onAuthError!(error);
              if (!refresh || cancelled || replaying) {
                if (!cancelled) controller.addError(error, stack);
                return;
              }
              refreshAndReplay(error, stack);
            },
            onDone: () {
              if (!cancelled && !replaying) controller.close();
            },
            cancelOnError: true,
          );
        } catch (error, stack) {
          // A synchronous throw from getToken/forward is not an auth failure to replay.
          if (!cancelled) controller.addError(error, stack);
        }
      }

      controller.onCancel = () async {
        cancelled = true;
        await forwardSub?.cancel();
      };
      run();
    });
  }
}
