import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:graphql_plus/graphql_plus.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A server that answers with [firstResponse] for the first request and
/// [secondResponse] for every request after it, recording each `Authorization`
/// header it sees.
class _AuthServer {
  _AuthServer({
    required this.firstResponse,
    required this.secondResponse,
    this.firstStatus = 200,
    this.secondStatus = 200,
  });

  final Map<String, dynamic> firstResponse;
  final Map<String, dynamic> secondResponse;

  /// HTTP status for the first response. Set to 401 when the test needs
  /// `HttpLink` to throw `HttpLinkServerException`; a 200 with a GraphQL `errors`
  /// body is delivered as a Response, not an exception.
  final int firstStatus;

  /// HTTP status for every response after the first.
  final int secondStatus;

  final List<String> seenAuthorization = [];
  late final HttpServer server;
  late final String url;

  int get hits => seenAuthorization.length;

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    url = 'http://127.0.0.1:${server.port}/graphql';
    server.listen((request) async {
      seenAuthorization.add(request.headers.value('authorization') ?? '<none>');
      final body =
          seenAuthorization.length == 1 ? firstResponse : secondResponse;
      request.response.statusCode =
          seenAuthorization.length == 1 ? firstStatus : secondStatus;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode(body));
      await request.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

Request _viewerRequest() => Request(
      operation: Operation(document: gql('{ viewer { id } }')),
    );

void main() {
  group('AuthLink', () {
    test('adds the token header to every request', () async {
      final server = _AuthServer(
        firstResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        AuthLink(getToken: () => 'Bearer token'),
        HttpLink(server.url),
      ]);

      await link.request(_viewerRequest()).first;

      expect(server.seenAuthorization, ['Bearer token']);
    });

    test('replays the original operation after refreshing the token', () async {
      // Mirrors issue #8: the first attempt is rejected, the link refreshes and
      // re-sends the same operation.
      final server = _AuthServer(
        firstStatus: 401,
        firstResponse: {
          'errors': [
            {'message': 'token expired'}
          ]
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      var tokenFetches = 0;
      final link = Link.from([
        AuthLink(
          // Each call mints a new token, so a replay that really re-fetches the
          // token is distinguishable from one that reuses the old header.
          getToken: () =>
              (tokenFetches++ == 0) ? 'Bearer stale' : 'Bearer fresh',
          onAuthError: (error) =>
              error is HttpLinkServerException &&
              error.response.statusCode == 401,
        ),
        HttpLink(server.url),
      ]);

      final result = await link.request(_viewerRequest()).first;

      expect(server.hits, 2, reason: 'the original operation must be re-sent');
      expect(server.seenAuthorization, ['Bearer stale', 'Bearer fresh']);
      expect(result.data, isNotNull);
      expect(result.errors, isNull);
    });

    test('the refresh callback can mint a new token', () async {
      final server = _AuthServer(
        firstStatus: 401,
        firstResponse: {
          'errors': [
            {'message': 'token expired'}
          ]
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      var token = 'Bearer stale';
      final link = Link.from([
        AuthLink(
          getToken: () async {
            final current = token;
            token = 'Bearer fresh';
            return current;
          },
          onAuthError: (_) => true,
        ),
        HttpLink(server.url),
      ]);

      await link.request(_viewerRequest()).first;

      expect(server.seenAuthorization, ['Bearer stale', 'Bearer fresh']);
    });

    test('surfaces the error when onAuthError declines', () async {
      final server = _AuthServer(
        firstStatus: 401,
        firstResponse: {
          'errors': [
            {'message': 'token expired'}
          ]
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        AuthLink(getToken: () => 'Bearer stale', onAuthError: (_) => false),
        HttpLink(server.url),
      ]);

      await expectLater(
        link.request(_viewerRequest()).first,
        throwsA(isA<HttpLinkServerException>()),
      );
      expect(server.hits, 1, reason: 'a declined refresh must not replay');
    });

    test('surfaces the error when no onAuthError is configured', () async {
      final server = _AuthServer(
        firstStatus: 401,
        firstResponse: {
          'errors': [
            {'message': 'token expired'}
          ]
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        AuthLink(getToken: () => 'Bearer stale'),
        HttpLink(server.url),
      ]);

      await expectLater(
        link.request(_viewerRequest()).first,
        throwsA(isA<HttpLinkServerException>()),
      );
      expect(server.hits, 1);
    });

    test('does not replay twice when the refresh also fails', () async {
      // Both responses are errors, so the second failure must surface rather than
      // triggering another replay.
      final server = _AuthServer(
        firstStatus: 401,
        secondStatus: 401,
        firstResponse: {
          'errors': [
            {'message': 'token expired'}
          ]
        },
        secondResponse: {
          'errors': [
            {'message': 'token still expired'}
          ]
        },
      );
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        AuthLink(getToken: () => 'Bearer stale', onAuthError: (_) => true),
        HttpLink(server.url),
      ]);

      await expectLater(
        link.request(_viewerRequest()).first,
        throwsA(isA<HttpLinkServerException>()),
      );
      expect(server.hits, 2, reason: 'exactly one replay');
    });

    test('a non-auth error is not replayed', () async {
      // The link only replays when onAuthError returns true. A 500 must surface as-is,
      // with exactly one network hit.
      final server = _AuthServer(
        firstStatus: 500,
        firstResponse: {
          'errors': [
            {'message': 'boom'}
          ]
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        AuthLink(
          getToken: () => 'Bearer token',
          onAuthError: (error) =>
              error is HttpLinkServerException &&
              error.response.statusCode == 401,
        ),
        HttpLink(server.url),
      ]);

      await expectLater(
        link.request(_viewerRequest()).first,
        throwsA(isA<HttpLinkServerException>()),
      );
      expect(server.hits, 1, reason: 'a non-auth error must not be replayed');
    });

    test('a replay preserves the original request context', () async {
      final server = _AuthServer(
        firstStatus: 401,
        firstResponse: {
          'errors': [
            {'message': 'token expired'}
          ]
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        AuthLink(getToken: () => 'Bearer token', onAuthError: (_) => true),
        HttpLink(server.url),
      ]);

      final request = _viewerRequest()
        ..updateContextEntry<HttpLinkHeaders>(
          (headers) => const HttpLinkHeaders(headers: {'X-Trace': 'abc123'}),
        );

      await link.request(request).first;

      expect(server.hits, 2, reason: 'the operation must be re-sent');
    });

    test('a consumer that cancels during the refresh sends no replay',
        () async {
      final server = _AuthServer(
        firstStatus: 401,
        firstResponse: {
          'errors': [
            {'message': 'token expired'}
          ]
        },
        secondResponse: {
          'data': {
            'viewer': {'id': '1'}
          }
        },
      );
      await server.start();
      addTearDown(server.stop);

      final refreshGate = Completer<void>();
      final firstHit = Completer<void>();
      var calls = 0;
      final link = Link.from([
        AuthLink(
          getToken: () async {
            calls++;
            // The initial fetch (call 1) returns immediately; the refresh blocks so the
            // test can cancel while it is in flight.
            if (calls >= 2) await refreshGate.future;
            return 'Bearer fresh';
          },
          onAuthError: (_) => true,
        ),
        _SignallingLink(
          url: server.url,
          onRequest: () {
            if (!firstHit.isCompleted) firstHit.complete();
          },
        ),
      ]);

      final sub = link.request(_viewerRequest()).listen((_) {});
      // Wait until the first request has actually reached the forward (and been rejected).
      await firstHit.future;
      // Give the refresh path a moment to start awaiting the gate.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await sub.cancel();
      refreshGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        server.hits,
        1,
        reason: 'a cancelled operation must not send the replay',
      );
    });

    test('concurrent 401s share a single refresh', () async {
      final refreshGate = Completer<void>();
      var calls = 0;
      final link = Link.from([
        AuthLink(
          getToken: () async {
            calls++;
            // Both initial fetches (calls 1-2) return immediately; the single shared
            // refresh (call 3) blocks so both requests pile into it.
            if (calls >= 3) await refreshGate.future;
            return 'Bearer token-$calls';
          },
          onAuthError: (_) => true,
        ),
        // A forward that always fails with an auth-shaped error, so every request
        // triggers the refresh path.
        _AlwaysFailingLink(),
      ]);

      final first = link
          .request(_viewerRequest())
          .toList()
          .catchError((_) => <Response>[]);
      final second = link
          .request(_viewerRequest())
          .toList()
          .catchError((_) => <Response>[]);
      // Let both requests reach the refresh before releasing it.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      refreshGate.complete();

      await Future.wait<void>([first, second]);

      expect(
        calls,
        3,
        reason:
            'two initial fetches plus one shared refresh (not one per request)',
      );
    });
  });
}

/// A [Link] that forwards to [HttpLink] but signals each request through [onRequest],
/// so a test can wait until a request has actually left the link.
class _SignallingLink extends Link {
  _SignallingLink({required this.url, required this.onRequest});

  final String url;
  final void Function() onRequest;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) {
    onRequest();
    return HttpLink(url).request(request);
  }
}

/// A [Link] whose `request` always throws an auth-shaped error, used to drive the
/// refresh path without a real network peer.
class _AlwaysFailingLink extends Link {
  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final parsed = Response(
      data: const {
        'errors': [
          {'message': 'token expired'}
        ]
      },
      response: const {},
    );
    throw HttpLinkServerException(
      response: http.Response('token expired', 401),
      parsedResponse: parsed,
      statusCode: 401,
    );
  }
}
