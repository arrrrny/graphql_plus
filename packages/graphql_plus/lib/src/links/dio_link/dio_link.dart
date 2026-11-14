import 'dart:async';

import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_http_link/gql_http_link.dart'
    show HttpLinkServerException, HttpLinkParserException;
import 'package:gql_link/gql_link.dart';
import 'package:http/http.dart' as http;

import 'package:graphql_plus/src/core/cancellation_token.dart';
import 'package:graphql_plus/src/exceptions.dart';

export 'package:gql_http_link/gql_http_link.dart'
    show HttpLinkServerException, HttpLinkParserException;

/// Decodes a [dio.Response] body into the map [ResponseParser] expects.
///
/// Replace it when a response needs a transformation before it is parsed — a
/// decrypted envelope, or a body only some endpoints wrap.
typedef DioResponseDecoder = FutureOr<Map<String, dynamic>?> Function(
  dio.Response<dynamic> response,
);

/// A terminating link that executes operations over HTTP with
/// [dio](https://pub.dev/packages/dio).
///
/// It carries the same semantics as [HttpLink] — the same request and response
/// encoding, the same [HttpLinkServerException] on a non-2xx status or on a
/// response missing both `data` and `errors`, and the same
/// [HttpLinkParserException] when a body will not parse — so an application can
/// move between the two transports without touching its error handling.
///
/// ## Why dio
///
/// Reach for this link when the application already uses dio for REST, or wants
/// what dio adds on top of `package:http`:
///
/// - **Interceptors** — an auth-refresh, logging or cookie interceptor written
///   once for REST applies to GraphQL too. Pass the configured `Dio()` and it
///   is used as-is; the link never closes a client it did not create.
/// - **Timeouts** — `connectTimeout`, `sendTimeout` and `receiveTimeout` are
///   dio's own `BaseOptions`.
/// - **Cookies** — a dio cookie interceptor carries the session cookies the
///   server sets. Without dio, [CookieLink] does the same job for either
///   transport.
///
/// Stay with [HttpLink] (or [CancellableHttpLink]) when there is no dio client
/// to share: `package:http` is the smaller dependency, and nothing here is
/// faster.
///
/// ## Usage
///
/// ```dart
/// final link = DioLink(
///   'https://api.example.com/graphql',
///   client: myDio, // shares interceptors, timeouts and cookie handling
/// );
///
/// final client = GraphQLClient(cache: GraphQLCache(), link: link);
/// ```
///
/// ## Cancellation
///
/// A [CancellationToken] in the request context becomes the request's
/// `CancelToken`, so `client.query(..., cancellationToken: token)` aborts the
/// in-flight exchange and surfaces a [CancelledException], exactly as
/// [CancellableHttpLink] does.
///
/// ## File uploads
///
/// Variables carrying an `http.MultipartFile` are sent as a GraphQL multipart
/// request in the same shape [HttpLink] sends — `operations`, `map` and one
/// part per file. The file objects are the `package:http` ones, so upload code
/// does not change with the transport.
///
/// ## Maintenance
///
/// Keep in sync with `gql_http_link`'s `HttpLink` and the in-tree
/// [CancellableHttpLink]: this link deliberately mirrors their header handling,
/// GET-for-queries encoding, multipart mapping, response parsing and exception
/// types, so the two transports stay interchangeable.
class DioLink extends Link {
  /// The endpoint URI of the GraphQL service.
  final Uri uri;

  /// The dio client every request goes through.
  ///
  /// Pass a configured instance to share interceptors, timeouts, cookie
  /// handling and connection pooling with the rest of the application. The link
  /// only closes a client it created itself.
  final dio.Dio client;

  /// Default HTTP headers to include in every request.
  final Map<String, String> defaultHeaders;

  /// Whether to use HTTP GET method for queries (not mutations).
  final bool useGETForQueries;

  /// Serializer for converting GraphQL requests to HTTP request bodies.
  final RequestSerializer serializer;

  /// Parser for converting HTTP response bodies to GraphQL responses.
  final ResponseParser parser;

  /// Decoder for HTTP response bodies.
  final DioResponseDecoder responseDecoder;

  final bool _ownsClient;

  static Map<String, dynamic>? _decodeMap(dio.Response<dynamic> response) {
    final Object? data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map<String, dynamic>((key, value) => MapEntry('$key', value));
    }
    if (data is String) return jsonDecode(data) as Map<String, dynamic>?;
    return null;
  }

  /// Creates a new [DioLink].
  ///
  /// [uri] is the endpoint of the GraphQL service.
  ///
  /// [client] is the dio client to send through; when it is omitted the link
  /// creates one and owns it.
  ///
  /// [defaultHeaders] are HTTP headers included in every request.
  ///
  /// [useGETForQueries] uses HTTP GET for query operations (not mutations).
  ///
  /// [serializer] converts GraphQL requests to HTTP bodies.
  ///
  /// [parser] converts HTTP response bodies to GraphQL responses.
  ///
  /// [responseDecoder] decodes a dio response body into a map.
  DioLink(
    String uri, {
    dio.Dio? client,
    this.defaultHeaders = const {},
    this.useGETForQueries = false,
    this.serializer = const RequestSerializer(),
    this.parser = const ResponseParser(),
    this.responseDecoder = _decodeMap,
  })  : uri = Uri.parse(uri),
        client = client ?? dio.Dio(),
        _ownsClient = client == null;

  @override
  Stream<Response> request(
    Request request, [
    NextLink? forward,
  ]) async* {
    final dioResponse = await _executeRequest(request);

    final response = await _parseHttpResponse(dioResponse);

    if ((dioResponse.statusCode ?? 0) >= 300 ||
        (response.data == null && response.errors == null)) {
      throw HttpLinkServerException(
        response: _asHttpResponse(dioResponse),
        parsedResponse: response,
        statusCode: dioResponse.statusCode,
      );
    }

    yield Response(
      data: response.data,
      errors: response.errors,
      response: response.response,
      context: _updateResponseContext(response, dioResponse),
    );
  }

  Future<dio.Response<dynamic>> _executeRequest(Request request) async {
    try {
      return await _send(request);
    } on dio.DioException catch (error, stackTrace) {
      if (error.type == dio.DioExceptionType.cancel) {
        throw CancelledException('HTTP request was cancelled');
      }
      throw ServerException(
        originalException: error,
        originalStackTrace: stackTrace,
        statusCode: error.response?.statusCode,
      );
    }
  }

  Future<dio.Response<dynamic>> _send(Request request) async {
    final body = _encodeAttempter(
      request,
      serializer.serializeRequest,
    )(request);

    final options = dio.Options(
      responseType: dio.ResponseType.json,
      headers: {
        'Content-Type': 'application/json',
        'Accept': '*/*',
        ...defaultHeaders,
        ..._getHttpLinkHeaders(request),
      },
      // The status check belongs to the link, so that a 4xx or 5xx reaches the
      // HttpLinkServerException both transports throw.
      validateStatus: (int? status) => true,
    );
    final encodedBody = _encodeAttempter(
      request,
      (Map<String, dynamic> body) => json.encode(
        body,
        toEncodable: (dynamic object) =>
            (object is http.MultipartFile) ? null : object.toJson(),
      ),
    )(body);

    final cancellation = _cancelTokenOf(request);
    try {
      final fileMap = _extractFlattenedFileMap(body);
      if (fileMap.isNotEmpty) {
        return await client.post<dynamic>(
          uri.toString(),
          data: _multipartBody(encodedBody, fileMap),
          options: options,
          cancelToken: cancellation?.token,
        );
      }

      if (useGETForQueries && _isQuery(request)) {
        return await client.getUri<dynamic>(
          uri.replace(
            queryParameters: _encodeAttempter(
              request,
              _encodeAsUriParams,
            )(body),
          ),
          options: options,
          cancelToken: cancellation?.token,
        );
      }

      return await client.post<dynamic>(
        uri.toString(),
        data: encodedBody,
        options: options,
        cancelToken: cancellation?.token,
      );
    } finally {
      cancellation?.release();
    }
  }

  dio.FormData _multipartBody(
    String encodedBody,
    Map<String, http.MultipartFile> fileMap,
  ) {
    final formBody = <String, dynamic>{
      'operations': encodedBody,
    };

    final fileMapping = <String, List<String>>{};
    final fileEntries = fileMap.entries.toList();
    for (var i = 0; i < fileEntries.length; i++) {
      final entry = fileEntries[i];
      final indexString = i.toString();
      fileMapping[indexString] = [entry.key];
      final file = entry.value;
      formBody[indexString] = dio.MultipartFile.fromStream(
        file.finalize,
        file.length,
        filename: file.filename,
        contentType: file.contentType,
      );
    }
    formBody['map'] = json.encode(fileMapping);

    return dio.FormData.fromMap(formBody);
  }

  /// Bridges the request's [CancellationToken] onto a dio `CancelToken`.
  ///
  /// The returned [Cancellation.release] drops the listener once the exchange
  /// is over, so a token that outlives the request keeps no subscription.
  static _Cancellation? _cancelTokenOf(Request request) {
    final CancellationToken? cancellationToken =
        request.context.entry<CancellationContextEntry>()?.token;
    if (cancellationToken == null) return null;

    final token = dio.CancelToken();
    if (cancellationToken.isCancelled) {
      token.cancel('cancelled');
      return _Cancellation(token, () {});
    }

    late final StreamSubscription<void> subscription;
    subscription = cancellationToken.onCancel.listen(
      (_) {
        if (!token.isCancelled) token.cancel('cancelled');
        subscription.cancel();
      },
      // A token disposed on normal completion emits nothing: the request is
      // left alone rather than aborted on the way out.
      onDone: () => subscription.cancel(),
      cancelOnError: false,
    );
    return _Cancellation(token, subscription.cancel);
  }

  Future<Response> _parseHttpResponse(
    dio.Response<dynamic> dioResponse,
  ) async {
    try {
      final body = await responseDecoder(dioResponse);
      return parser.parseResponse(body!);
    } catch (e, stackTrace) {
      throw HttpLinkParserException(
        originalException: e,
        originalStackTrace: stackTrace,
        response: _asHttpResponse(dioResponse),
      );
    }
  }

  Context _updateResponseContext(
    Response response,
    dio.Response<dynamic> dioResponse,
  ) {
    try {
      return response.context.withEntry(
        HttpLinkResponseContext(
          statusCode: dioResponse.statusCode ?? 0,
          rawHeaders: dioResponse.headers.map,
        ),
      );
    } catch (e, stackTrace) {
      throw ContextWriteException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    }
  }

  /// An `http.Response` snapshot of [dioResponse].
  ///
  /// The exception types this link reuses are `package:http`'s, so they carry
  /// one; dio keeps only the decoded body, so the body is re-encoded rather
  /// than copied verbatim.
  static http.Response _asHttpResponse(dio.Response<dynamic> dioResponse) {
    final Object? data = dioResponse.data;
    var body = '';
    try {
      body = data is String ? data : jsonEncode(data);
    } catch (_) {
      body = '';
    }
    return http.Response(
      body,
      dioResponse.statusCode ?? 0,
      headers: dioResponse.headers.map.map(
        (name, values) => MapEntry(name, values.join(', ')),
      ),
      request: http.Request(
        dioResponse.requestOptions.method,
        dioResponse.requestOptions.uri,
      ),
    );
  }

  /// Wrap an encoding transform in exception handling
  T Function(V) _encodeAttempter<T, V>(
    Request request,
    T Function(V) encoder,
  ) =>
      (V input) {
        try {
          return encoder(input);
        } catch (e, stackTrace) {
          throw RequestFormatException(
            originalException: e,
            originalStackTrace: stackTrace,
            request: request,
          );
        }
      };

  Map<String, String> _getHttpLinkHeaders(Request request) {
    try {
      final HttpLinkHeaders? linkHeaders = request.context.entry();
      return {
        if (linkHeaders != null) ...linkHeaders.headers,
      };
    } catch (e, stackTrace) {
      throw ContextReadException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    }
  }

  bool _isQuery(Request request) {
    final definitions = request.operation.document.definitions
        .whereType<OperationDefinitionNode>()
        .toList();
    if (request.operation.operationName != null) {
      definitions.removeWhere(
        (node) => node.name!.value != request.operation.operationName,
      );
    }
    if (definitions.length != 1) return false;
    return definitions.first.type == OperationType.query;
  }

  Map<String, String> _encodeAsUriParams(Map<String, dynamic> serialized) =>
      serialized.map<String, String>(
        (k, dynamic v) => MapEntry(k, v is String ? v : json.encode(v)),
      );

  @override
  Future<void> dispose() async {
    if (_ownsClient) client.close(force: true);
  }
}

/// The dio `CancelToken` a request sends with, and how to let go of the
/// [CancellationToken] listener that feeds it.
class _Cancellation {
  const _Cancellation(this.token, this.release);

  final dio.CancelToken token;
  final void Function() release;
}

/// Recursively extract [http.MultipartFile]s and return them as a normalized
/// map of `path` => file.
///
/// ```dart
/// {
///   "foo": [ { "bar": MultipartFile("blah.txt") } ]
/// }
/// // =>
/// {
///   "foo.0.bar": MultipartFile("blah.txt")
/// }
/// ```
Map<String, http.MultipartFile> _extractFlattenedFileMap(
  dynamic body, {
  Map<String, http.MultipartFile>? currentMap,
  List<String> currentPath = const <String>[],
}) {
  currentMap ??= <String, http.MultipartFile>{};
  if (body is Map<String, dynamic>) {
    for (final entry in body.entries) {
      currentMap.addAll(_extractFlattenedFileMap(
        entry.value,
        currentMap: currentMap,
        currentPath: List<String>.from(currentPath)..add(entry.key),
      ));
    }
    return currentMap;
  }
  if (body is List<dynamic>) {
    for (var i = 0; i < body.length; i++) {
      currentMap.addAll(_extractFlattenedFileMap(
        body[i],
        currentMap: currentMap,
        currentPath: List<String>.from(currentPath)..add(i.toString()),
      ));
    }
    return currentMap;
  }
  if (body is http.MultipartFile) {
    return currentMap
      ..addAll({
        currentPath.join('.'): body,
      });
  }
  return currentMap;
}
