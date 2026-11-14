import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

/// What a [CookieLink] does with cookies, mirroring the Fetch standard's
/// `Request.credentials`.
enum Credentials {
  /// Neither sends cookies nor records the ones a response sets.
  omit,

  /// Sends and records cookies belonging to the endpoint's own origin.
  sameOrigin,

  /// Sends and records every stored cookie, including one set by another
  /// origin (an SSO domain, for example).
  include,
}

/// The cookie store a [CookieLink] reads from and writes to.
///
/// Implement this to back the link with a real jar — for example the
/// `cookie_jar` package that dio uses. [InMemoryCookieStore] is the default
/// and is enough for a session cookie that only has to outlive the process.
abstract class CookieStore {
  /// The `Cookie` request header value for [uri], or `null` when no stored
  /// cookie applies.
  ///
  /// [sameOriginOnly] is [Credentials.sameOrigin]: when true, a cookie whose
  /// domain is a parent of [uri]'s host is not returned.
  String? cookieHeaderFor(Uri uri, {bool sameOriginOnly = true});

  /// Records every cookie carried by the `Set-Cookie` headers in [headers] as
  /// set by [uri].
  void addCookiesFromResponse(Uri uri, Map<String, String> headers);
}

/// A [CookieStore] that keeps cookies in memory for the life of the process.
///
/// It implements the parts of RFC 6265 a GraphQL client needs: domain and path
/// matching, `Secure`, `Max-Age` and `Expires` (including expiry as deletion),
/// and replacement of a cookie by name/domain/path. `SameSite` is not modelled —
/// the link is not a browser and has no site context to apply it to.
class InMemoryCookieStore implements CookieStore {
  InMemoryCookieStore({this.capacity = 300}) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  /// How many cookies are kept before the oldest are dropped.
  final int capacity;

  final List<_Cookie> _cookies = <_Cookie>[];

  @override
  String? cookieHeaderFor(Uri uri, {bool sameOriginOnly = true}) {
    final DateTime now = DateTime.now().toUtc();
    _cookies.removeWhere((_Cookie cookie) => cookie.isExpiredAt(now));

    final List<_Cookie> matching = _cookies
        .where(
          (_Cookie cookie) =>
              cookie.matches(uri, sameOriginOnly: sameOriginOnly),
        )
        .toList()
      ..sort((_Cookie a, _Cookie b) => b.path.length.compareTo(a.path.length));

    if (matching.isEmpty) return null;
    return matching
        .map((_Cookie cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  @override
  void addCookiesFromResponse(Uri uri, Map<String, String> headers) {
    final String? header = _readHeader(headers, 'set-cookie');
    if (header == null) return;

    final DateTime now = DateTime.now().toUtc();
    for (final String entry in _splitSetCookieHeader(header)) {
      final _Cookie? cookie = _Cookie.parse(entry, uri, now);
      if (cookie == null) continue;
      _cookies.removeWhere((_Cookie existing) => existing.replaces(cookie));
      // A cookie that is already expired is a deletion request, not a record.
      if (cookie.isExpiredAt(now)) continue;
      _cookies.add(cookie);
    }

    if (_cookies.length > capacity) {
      _cookies.removeRange(0, _cookies.length - capacity);
    }
  }

  static String? _readHeader(Map<String, String> headers, String name) {
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }
}

/// Splits a possibly-joined `Set-Cookie` header into individual cookies.
///
/// `package:http` collapses repeated headers into one comma-joined value, so
/// `a=1; Path=/` and `b=2; Path=/` arrive as `a=1; Path=/, b=2; Path=/`. A plain
/// `split(',')` would also cut `Expires=Wed, 21 Oct 2037 07:28:00 GMT` in half,
/// so a comma is only treated as a separator when what follows it starts a new
/// `name=` pair.
List<String> _splitSetCookieHeader(String header) => header
    .split(_cookieSeparator)
    .map((String cookie) => cookie.trim())
    .where((String cookie) => cookie.isNotEmpty)
    .toList();

final RegExp _cookieSeparator =
    RegExp(r",\s*(?=[!#$%&'*+\-.^_`|~0-9A-Za-z]+=)");

/// A link that keeps session cookies flowing with GraphQL requests.
///
/// This is the cookie-based counterpart of [AuthLink]: [AuthLink] attaches a
/// header the application mints, while [CookieLink] carries the cookies the
/// server sets. Place it before the HTTP link in the chain, and give it the same
/// endpoint the HTTP link talks to:
///
/// ```dart
/// final link = Link.from([
///   CookieLink(uri: Uri.parse('https://api.example.com/graphql')),
///   HttpLink('https://api.example.com/graphql'),
/// ]);
/// ```
///
/// Cookies set by a response are recorded and sent on every later request, so a
/// login mutation followed by an authenticated query needs no per-request work.
/// An explicit `Cookie` header on the request wins over the store, which is what
/// makes a hand-built header still possible.
///
/// [credentials] defaults to [Credentials.sameOrigin]. Use
/// [Credentials.include] when the session cookie is set by another origin (an
/// SSO domain) and must still be sent, and [Credentials.omit] to switch cookie
/// handling off entirely.
///
/// Cookie policy itself is the [CookieStore]'s; pass your own to share a jar
/// with the rest of the application.
class CookieLink extends Link {
  CookieLink({
    required this.uri,
    this.credentials = Credentials.sameOrigin,
    CookieStore? cookieStore,
  }) : cookieStore = cookieStore ?? InMemoryCookieStore();

  /// The endpoint the link is scoped to. Cookies are matched against its host,
  /// and `Set-Cookie` from a response is recorded as coming from it.
  final Uri uri;

  /// Which cookies are sent and recorded. See [Credentials].
  final Credentials credentials;

  /// The jar the link reads and writes.
  final CookieStore cookieStore;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final NextLink next = forward!;
    final bool tracked = credentials != Credentials.omit;
    final String? cookie = tracked
        ? cookieStore.cookieHeaderFor(
            uri,
            sameOriginOnly: credentials == Credentials.sameOrigin,
          )
        : null;

    await for (final Response response in next(_withCookie(request, cookie))) {
      if (tracked) {
        final HttpLinkResponseContext? context =
            response.context.entry<HttpLinkResponseContext>();
        final Map<String, String>? headers = context?.headers;
        if (headers != null) {
          cookieStore.addCookiesFromResponse(uri, headers);
        }
      }
      yield response;
    }
  }

  /// Returns [request] with [cookie] as its `Cookie` header.
  ///
  /// A `Cookie` header already on the request is left alone: an application that
  /// sets one by hand has made a deliberate choice the store must not overrule.
  static Request _withCookie(Request request, String? cookie) {
    if (cookie == null || cookie.isEmpty) return request;

    final HttpLinkHeaders? existing = request.context.entry<HttpLinkHeaders>();
    final Map<String, String> headers =
        existing?.headers ?? const <String, String>{};
    final bool explicit =
        headers.keys.any((String key) => key.toLowerCase() == 'cookie');
    if (explicit) return request;

    return request.updateContextEntry<HttpLinkHeaders>(
      (HttpLinkHeaders? current) => HttpLinkHeaders(
        headers: <String, String>{
          ...current?.headers ?? const <String, String>{},
          'Cookie': cookie,
        },
      ),
    );
  }
}

/// Parses an HTTP date in any of the three RFC 6265 §5.1.1 formats:
/// IMF-fixdate (`Wed, 21 Oct 2015 07:28:00 GMT`), the obsolete RFC 850
/// two-digit-year form, or asctime (`Sun Nov  6 08:49:37 1994`). The leading
/// weekday name is optional, and in the first two forms the day may be
/// separated from the month by a space or a dash. Returns `null` for anything
/// else, which callers treat as "no expiry".
DateTime? _parseHttpDate(String input) {
  final String trimmed = input.trim();

  // IMF-fixdate / RFC 850: day before month, year after the time.
  final RegExpMatch? match = _httpDate.firstMatch(trimmed);
  if (match != null) {
    final int? month = _months[match.group(2)!.toLowerCase()];
    if (month == null) return null;
    return DateTime.utc(
      _httpYear(int.parse(match.group(3)!)),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  // asctime: month before day, year last, the day space-padded to two.
  final RegExpMatch? asctime = _asctimeDate.firstMatch(trimmed);
  if (asctime != null) {
    final int? month = _months[asctime.group(1)!.toLowerCase()];
    if (month == null) return null;
    return DateTime.utc(
      int.parse(asctime.group(6)!),
      month,
      int.parse(asctime.group(2)!),
      int.parse(asctime.group(3)!),
      int.parse(asctime.group(4)!),
      int.parse(asctime.group(5)!),
    );
  }

  return null;
}

final RegExp _httpDate = RegExp(
  r'^(?:[A-Za-z]+,\s*)?(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4})[ T](\d{2}):(\d{2}):(\d{2})',
);

final RegExp _asctimeDate = RegExp(
  r'^(?:[A-Za-z]+\s+)?([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})',
);

/// Folds a two-digit year into the century RFC 6265 §5.1.1 assumes: `0-69`
/// means 2000+, `70-99` means 1900+.
int _httpYear(int parsed) =>
    parsed < 100 ? (parsed < 70 ? 2000 + parsed : 1900 + parsed) : parsed;

const Map<String, int> _months = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// One stored cookie.
class _Cookie {
  const _Cookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.secure,
    required this.expiresAt,
  });

  final String name;
  final String value;

  /// Lower-cased host the cookie belongs to, without a leading dot.
  final String domain;

  final String path;
  final bool secure;
  final DateTime? expiresAt;

  static final RegExp _name = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

  /// Parses one `Set-Cookie` value as set by [requestUri].
  ///
  /// Returns `null` when the value has no `name=value` pair or the name is not
  /// a valid token, which is what a malformed header looks like.
  static _Cookie? parse(String header, Uri requestUri, DateTime now) {
    final List<String> parts = header.split(';');
    final String pair = parts.first.trim();
    final int separator = pair.indexOf('=');
    if (separator <= 0) return null;

    final String name = pair.substring(0, separator).trim();
    if (!_name.hasMatch(name)) return null;
    final String value = pair.substring(separator + 1).trim();
    if (value.contains(';')) return null;

    String domain = requestUri.host.toLowerCase();
    String path = _defaultPath(requestUri.path);
    bool secure = false;
    bool hasMaxAge = false;
    int? maxAge;
    DateTime? expiresAt;

    for (final String part in parts.skip(1)) {
      final String attribute = part.trim();
      if (attribute.isEmpty) continue;

      final int split = attribute.indexOf('=');
      final String key =
          (split == -1 ? attribute : attribute.substring(0, split))
              .trim()
              .toLowerCase();
      final String raw =
          split == -1 ? '' : attribute.substring(split + 1).trim();

      switch (key) {
        case 'domain':
          final String candidate =
              raw.toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
          if (candidate.isNotEmpty) {
            // RFC 6265 §5.3 step 6: a `Domain` the request host does not
            // domain-match makes the cookie ignored entirely — otherwise a
            // response from one origin could plant a cookie for another.
            if (!_domainMatches(requestUri.host.toLowerCase(), candidate)) {
              return null;
            }
            domain = candidate;
          }
        case 'path':
          if (raw.startsWith('/')) path = raw;
        case 'secure':
          secure = true;
        case 'max-age':
          // Presence matters: a `Max-Age` that does not parse as an integer
          // means the cookie is ignored entirely (RFC 6265 §5.2.2), not a
          // fall back to `Expires`.
          hasMaxAge = true;
          maxAge = int.tryParse(raw);
        case 'expires':
          expiresAt = _parseHttpDate(raw);
      }
    }

    // RFC 6265 §5.3 step 10: a `Secure` cookie set over a non-secure channel
    // is ignored entirely.
    if (secure && requestUri.scheme != 'https') return null;
    if (hasMaxAge && maxAge == null) return null;

    return _Cookie(
      name: name,
      value: value,
      domain: domain,
      path: path,
      secure: secure,
      // `Max-Age` wins over `Expires`: it is relative to now and unambiguous.
      expiresAt:
          maxAge == null ? expiresAt : now.add(Duration(seconds: maxAge)),
    );
  }

  bool isExpiredAt(DateTime now) {
    final DateTime? expiry = expiresAt;
    return expiry != null && !expiry.isAfter(now);
  }

  /// Whether [host] domain-matches [domain] (RFC 6265 §5.1.3): the two are
  /// equal, or [host] is a subdomain ending in `.` + [domain]. An IP address
  /// host matches only itself, so the suffix form requires a host name.
  static bool _domainMatches(String host, String domain) =>
      host == domain || (host.endsWith('.$domain') && !_ipv4.hasMatch(host));

  static final RegExp _ipv4 = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');

  /// Whether this cookie is stored under the same name, domain and path as
  /// [other] — the identity RFC 6265 replaces on.
  bool replaces(_Cookie other) =>
      name == other.name && domain == other.domain && path == other.path;

  bool matches(Uri uri, {required bool sameOriginOnly}) {
    final DateTime? expiry = expiresAt;
    if (expiry != null && !expiry.isAfter(DateTime.now().toUtc())) return false;
    if (secure && uri.scheme != 'https') return false;

    // [Credentials.sameOrigin] confines the jar to the endpoint's origin;
    // [Credentials.include] has already opted into another origin's cookie, so
    // there is no host to check it against.
    if (sameOriginOnly) {
      final String host = uri.host.toLowerCase();
      if (host != domain && !host.endsWith('.$domain')) return false;
    }

    return _pathMatches(uri.path);
  }

  bool _pathMatches(String requestPath) {
    if (requestPath == path) return true;
    final String prefix = path.endsWith('/') ? path : '$path/';
    return requestPath.startsWith(prefix);
  }

  /// The directory of [requestPath], used when a cookie carries no `Path`.
  static String _defaultPath(String requestPath) {
    if (!requestPath.startsWith('/')) return '/';
    final int lastSlash = requestPath.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : requestPath.substring(0, lastSlash);
  }
}
