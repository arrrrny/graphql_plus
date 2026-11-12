import 'dart:convert';
import 'dart:io';

import 'package:graphql_plus/graphql_plus.dart';
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
  });
}
