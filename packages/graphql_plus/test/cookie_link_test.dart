import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:graphql_plus/graphql_plus.dart';
import 'package:test/test.dart';

/// One scripted HTTP reply: the `Set-Cookie` headers the server sends with it.
class _Reply {
  const _Reply({this.setCookies = const []});

  final List<String> setCookies;
}

/// An HTTP server that records the `Cookie` header of every request and
/// answers with [replies] in order, repeating the last one.
class _CookieServer {
  _CookieServer(this.replies);

  final List<_Reply> replies;

  final List<String?> seenCookie = [];
  late final HttpServer server;
  late final String url;

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    url = 'http://127.0.0.1:${server.port}/graphql';
    server.listen((request) async {
      seenCookie.add(request.headers.value('cookie'));
      final index = seenCookie.length - 1 < replies.length
          ? seenCookie.length - 1
          : replies.length - 1;
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      for (final cookie in replies[index].setCookies) {
        request.response.headers.add('set-cookie', cookie);
      }
      request.response.write(
        json.encode(const {
          'data': {
            'viewer': {'id': '1'}
          }
        }),
      );
      await request.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

/// A [CookieStore] that always answers with [header] and records every
/// response it is fed — the seam a `cookie_jar` adapter plugs into.
class _SeededCookieStore implements CookieStore {
  _SeededCookieStore(this.header);

  final String header;
  final List<Map<String, String>> calls = [];

  @override
  String? cookieHeaderFor(Uri uri, {bool sameOriginOnly = true}) => header;

  @override
  void addCookiesFromResponse(Uri uri, Map<String, String> headers) {
    calls.add(headers);
  }
}

Request _viewerRequest({Map<String, String> headers = const {}}) => Request(
      operation: Operation(document: gql('{ viewer { id } }')),
      context: headers.isEmpty
          ? const Context()
          : Context.fromList([HttpLinkHeaders(headers: headers)]),
    );

/// Drives [link] through two requests so the second one observes whatever the
/// first response stored.
Future<void> _twoRequests(Link link) async {
  await link.request(_viewerRequest()).first;
  await link.request(_viewerRequest()).first;
}

void main() {
  group('CookieLink', () {
    test('sends the cookies it learned from a previous response', () async {
      final server = _CookieServer([
        _Reply(setCookies: ['session=abc; Path=/']),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        HttpLink(server.url),
      ]);

      await _twoRequests(link);

      expect(server.seenCookie, [isNull, 'session=abc']);
    });

    test('Credentials.omit neither sends nor records cookies', () async {
      final server = _CookieServer([
        _Reply(setCookies: ['session=abc; Path=/']),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url), credentials: Credentials.omit),
        HttpLink(server.url),
      ]);

      await _twoRequests(link);

      expect(server.seenCookie, [isNull, isNull]);
    });

    test('a custom CookieStore is the seam a cookie_jar adapter plugs into',
        () async {
      final server = _CookieServer([
        _Reply(setCookies: ['session=abc; Path=/']),
      ]);
      await server.start();
      addTearDown(server.stop);

      final store = _SeededCookieStore('manual=1');
      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url), cookieStore: store),
        HttpLink(server.url),
      ]);

      await link.request(_viewerRequest()).first;

      expect(server.seenCookie, ['manual=1']);
      expect(store.calls, hasLength(1));
      expect(store.calls.single['set-cookie'], contains('session=abc'));
    });

    test('an explicit Cookie header is not overwritten', () async {
      final server = _CookieServer([
        _Reply(setCookies: ['session=abc; Path=/']),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        HttpLink(server.url),
      ]);

      await link.request(_viewerRequest()).first;
      await link.request(_viewerRequest(headers: {'Cookie': 'manual=1'})).first;

      expect(server.seenCookie, [isNull, 'manual=1']);
    });

    test('records several cookies set by one response', () async {
      final server = _CookieServer([
        _Reply(setCookies: ['a=1; Path=/', 'b=2; Path=/']),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        HttpLink(server.url),
      ]);

      await _twoRequests(link);

      // The header is a `; `-joined list in path-length order; both cookies
      // must survive.
      expect(server.seenCookie.last, anyOf('a=1; b=2', 'b=2; a=1'));
    });

    test('an Expires value with a comma is parsed as one cookie, not two',
        () async {
      // The comma inside the date must not start a new cookie: `a=1` is
      // already expired, so a parser that split there would keep it as a
      // session cookie and send `a=1; b=2`.
      final server = _CookieServer([
        _Reply(
          setCookies: [
            'a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/',
            'b=2; Path=/',
          ],
        ),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        HttpLink(server.url),
      ]);

      await _twoRequests(link);

      expect(server.seenCookie.last, 'b=2');
    });

    test('keeps a cookie whose Expires is in the future', () async {
      final server = _CookieServer([
        _Reply(
          setCookies: ['a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/'],
        ),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        HttpLink(server.url),
      ]);

      await _twoRequests(link);

      expect(server.seenCookie.last, 'a=1');
    });

    test('Max-Age=0 deletes a stored cookie', () async {
      final server = _CookieServer([
        _Reply(setCookies: ['session=abc; Path=/']),
        _Reply(setCookies: ['session=; Max-Age=0; Path=/']),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        HttpLink(server.url),
      ]);

      await link.request(_viewerRequest()).first;
      await link.request(_viewerRequest()).first;
      await link.request(_viewerRequest()).first;

      expect(server.seenCookie[1], 'session=abc');
      expect(server.seenCookie[2], isNull);
    });

    test('does not send a Secure cookie over http', () async {
      final server = _CookieServer([
        _Reply(setCookies: ['s=1; Secure; Path=/']),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        HttpLink(server.url),
      ]);

      await _twoRequests(link);

      expect(server.seenCookie.last, isNull);
    });

    test('Credentials.sameOrigin ignores a cookie set by another origin',
        () async {
      final server = _CookieServer([_Reply()]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(
          uri: Uri.parse(server.url),
          cookieStore: _crossOriginStore(),
        ),
        HttpLink(server.url),
      ]);

      await link.request(_viewerRequest()).first;

      expect(server.seenCookie, [isNull]);
    });

    test('Credentials.include sends a cookie set by another origin', () async {
      final server = _CookieServer([_Reply()]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(
          uri: Uri.parse(server.url),
          credentials: Credentials.include,
          cookieStore: _crossOriginStore(),
        ),
        HttpLink(server.url),
      ]);

      await link.request(_viewerRequest()).first;

      expect(server.seenCookie, ['sso=xyz']);
    });

    test('works over CancellableHttpLink too', () async {
      final server = _CookieServer([
        _Reply(setCookies: ['session=abc; Path=/']),
        _Reply(),
      ]);
      await server.start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        CancellableHttpLink(server.url),
      ]);

      await _twoRequests(link);

      expect(server.seenCookie, [isNull, 'session=abc']);
    });
  });

  group('InMemoryCookieStore', () {
    test('sends a Domain cookie to subdomains of the attribute', () {
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('https://api.example.com/graphql'),
          const {'set-cookie': 's=1; Domain=example.com; Path=/'},
        );

      expect(
        store.cookieHeaderFor(Uri.parse('https://sub.example.com/graphql')),
        's=1',
      );
      expect(
        store.cookieHeaderFor(Uri.parse('https://api.example.com/graphql')),
        's=1',
      );
    });

    test('ignores a Domain cookie the request host does not domain-match', () {
      // RFC 6265 §5.3 step 6: a response cannot plant a cookie for another
      // domain, so the jar stays empty for the planting origin too.
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('https://api.example.com/graphql'),
          const {'set-cookie': 'pwn=1; Domain=evil.com; Path=/'},
        );

      expect(
        store.cookieHeaderFor(Uri.parse('https://api.example.com/graphql')),
        isNull,
      );
      expect(store.cookieHeaderFor(Uri.parse('https://evil.com/')), isNull);
    });

    test('matches a path and its children, not a sibling that extends it', () {
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/graphql'),
          const {'set-cookie': 's=1; Path=/foo'},
        );

      expect(store.cookieHeaderFor(Uri.parse('https://h.example/foo')), 's=1');
      expect(
        store.cookieHeaderFor(Uri.parse('https://h.example/foo/bar')),
        's=1',
      );
      expect(
          store.cookieHeaderFor(Uri.parse('https://h.example/foobar')), isNull);
    });

    test('evicts the oldest cookies beyond capacity', () {
      // One comma-joined header, the way `package:http` delivers several
      // `Set-Cookie` headers.
      final store = InMemoryCookieStore(capacity: 2)
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {'set-cookie': 'a=1; Path=/, b=2; Path=/, c=3; Path=/'},
        );

      final header = store.cookieHeaderFor(Uri.parse('https://h.example/'));
      expect(header, isNot(contains('a=')));
      expect(header, contains('b=2'));
      expect(header, contains('c=3'));
    });

    test('folds an RFC 850 two-digit-year Expires by RFC 6265 rules', () {
      // RFC 6265 §5.1.1: 00-69 means 2000+, 70-99 means 1900+ — so an `68`
      // date is in the future while a `94` one is long past (a deletion).
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {
            'set-cookie':
                'kept=1; Expires=Sunday, 06-Nov-68 08:49:37 GMT; Path=/',
          },
        )
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {
            'set-cookie':
                'gone=2; Expires=Sunday, 06-Nov-94 08:49:37 GMT; Path=/',
          },
        );

      expect(store.cookieHeaderFor(Uri.parse('https://h.example/')), 'kept=1');
    });

    test('parses an asctime Expires date', () {
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {
            'set-cookie': 'kept=1; Expires=Sun Nov  6 08:49:37 2037; Path=/',
          },
        )
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {
            'set-cookie': 'gone=2; Expires=Sun Nov  6 08:49:37 1994; Path=/',
          },
        );

      // The past-date cookie is expired at set time, so it is a deletion
      // request, not a record.
      expect(store.cookieHeaderFor(Uri.parse('https://h.example/')), 'kept=1');
    });

    test('ignores a cookie whose Max-Age does not parse', () {
      // RFC 6265 §5.2.2: a present-but-unparseable `Max-Age` means ignore the
      // cookie entirely, not a fall back to `Expires`.
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {
            'set-cookie':
                'a=1; Max-Age=abc; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/',
          },
        );

      expect(store.cookieHeaderFor(Uri.parse('https://h.example/')), isNull);
    });

    test('does not store a Secure cookie set over http', () {
      // RFC 6265 §5.3 step 10: ignored at set time, so it never reaches even
      // an https request through the store.
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('http://h.example/'),
          const {'set-cookie': 's=1; Secure; Path=/'},
        );

      expect(store.cookieHeaderFor(Uri.parse('https://h.example/')), isNull);
    });

    test('ignores a cookie with a malformed name', () {
      final store = InMemoryCookieStore()
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {'set-cookie': 'p wn=1; Path=/'},
        )
        ..addCookiesFromResponse(
          Uri.parse('https://h.example/'),
          const {'set-cookie': '=2; Path=/'},
        );

      expect(store.cookieHeaderFor(Uri.parse('https://h.example/')), isNull);
    });
  });
}

/// A store holding one cookie that belongs to `sso.example`, not to the test
/// server's origin.
CookieStore _crossOriginStore() => InMemoryCookieStore()
  ..addCookiesFromResponse(
    Uri.parse('http://sso.example/'),
    const {'set-cookie': 'sso=xyz; Domain=sso.example; Path=/'},
  );
