import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:gql/language.dart';
import 'package:graphql_plus/graphql_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:test/test.dart';

/// A snapshot of one request the link sent.
class _Sent {
  _Sent(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;

  String? get header => headers['x-intercepted'];
  String? get cookie => headers['cookie'];
}

/// A GraphQL endpoint over a real HTTP server, recording what it is sent.
class _Server {
  _Server({
    this.status = 200,
    this.body = '{"data": {"viewer": {"id": "1"}}}',
    this.setCookies = const [],
    this.delay = Duration.zero,
  });

  final int status;
  final String body;
  final List<String> setCookies;
  final Duration delay;

  final List<_Sent> sent = [];

  late final HttpServer server;
  late final String url;

  Future<_Server> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    url = 'http://127.0.0.1:${server.port}/graphql';
    server.listen((request) async {
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      final payload = await utf8.decodeStream(request);
      sent.add(_Sent(request.method, request.uri, headers, payload));

      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }

      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      for (final cookie in setCookies) {
        request.response.headers.add('set-cookie', cookie);
      }
      request.response.write(body);
      await request.response.close();
    });
    return this;
  }

  Future<void> stop() => server.close(force: true);
}

Request _request({
  String source = 'query { viewer { id } }',
  Map<String, dynamic> variables = const {},
  Map<String, String> headers = const {},
  CancellationToken? cancellationToken,
}) {
  final context = <ContextEntry>[
    if (headers.isNotEmpty) HttpLinkHeaders(headers: headers),
    if (cancellationToken != null) CancellationContextEntry(cancellationToken),
  ];
  return Request(
    operation: Operation(document: parseString(source)),
    variables: variables,
    context: Context.fromList(context),
  );
}

Future<Object> _errorOf(Link link, Request request) async {
  try {
    await link.request(request).drain<void>();
  } catch (error) {
    return error;
  }
  fail('expected the request to fail');
}

void main() {
  group('DioLink', () {
    test('executes an operation and parses the response', () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      final responses = await link.request(_request()).toList();

      expect(responses, hasLength(1));
      expect(responses.single.data, {
        'viewer': {'id': '1'}
      });
      expect(responses.single.errors, isNull);
      await link.dispose();
    });

    test('runs the interceptors of the Dio client it is given', () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final client = dio.Dio()
        ..interceptors.add(
          dio.InterceptorsWrapper(
            onRequest: (options, handler) {
              options.headers['x-intercepted'] = 'yes';
              handler.next(options);
            },
          ),
        );

      final link = DioLink(server.url, client: client);
      await link.request(_request()).drain<void>();

      expect(server.sent, hasLength(1));
      expect(server.sent.single.header, 'yes');
      await link.dispose();
    });

    test('keeps the caller able to use a Dio client it owns', () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final client = dio.Dio();
      final link = DioLink(server.url, client: client);
      await link.request(_request()).drain<void>();
      await link.dispose();

      final response = await client.get<dynamic>(server.url);
      expect(response.statusCode, 200);
      client.close(force: true);
    });

    test('closes a Dio client it created itself', () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      await link.request(_request()).drain<void>();
      await link.dispose();

      expect(
        () => link.client.get<dynamic>(server.url),
        throwsA(isA<dio.DioException>()),
      );
    });

    test('sends a GET with the operation encoded when useGETForQueries',
        () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final link = DioLink(server.url, useGETForQueries: true);
      await link.request(_request()).drain<void>();

      expect(server.sent, hasLength(1));
      expect(server.sent.single.method, 'GET');
      expect(
          server.sent.single.uri.queryParameters['query'], contains('viewer'));
      await link.dispose();
    });

    test('POSTs a mutation even when useGETForQueries is set', () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final link = DioLink(server.url, useGETForQueries: true);
      await link.request(_request(source: 'mutation { ping }')).drain<void>();

      expect(server.sent, hasLength(1));
      expect(server.sent.single.method, 'POST');
      await link.dispose();
    });

    test('attaches the default headers and the request headers', () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final link = DioLink(
        server.url,
        defaultHeaders: const {'x-default': 'default'},
      );
      await link
          .request(_request(headers: const {'x-request': 'request'}))
          .drain<void>();

      expect(server.sent, hasLength(1));
      expect(server.sent.single.headers['x-default'], 'default');
      expect(server.sent.single.headers['x-request'], 'request');
      await link.dispose();
    });

    test('exposes the response status code and headers in the context',
        () async {
      final server = await _Server(
        body: '{"data": {"viewer": {"id": "1"}}}',
      ).start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      final response = await link.request(_request()).first;

      final context = response.context.entry<HttpLinkResponseContext>();
      expect(context, isNotNull);
      expect(context!.statusCode, 200);
      expect(context.headers!['content-type'], contains('application/json'));
      await link.dispose();
    });

    test('surfaces a non-2xx response as HttpLinkServerException', () async {
      final server = await _Server(
        status: 503,
        body: '{"errors": [{"message": "unavailable"}]}',
      ).start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      final error = await _errorOf(link, _request());

      expect(error, isA<HttpLinkServerException>());
      expect((error as HttpLinkServerException).statusCode, 503);
      await link.dispose();
    });

    test('returns the GraphQL errors a 200 response reports', () async {
      final server = await _Server(
        body: '{"errors": [{"message": "nope"}]}',
      ).start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      final response = await link.request(_request()).first;

      expect(response.data, isNull);
      expect(response.errors, isNotNull);
      expect(response.errors!.single.message, 'nope');
      await link.dispose();
    });

    test('surfaces a response it cannot parse as HttpLinkParserException',
        () async {
      final server = await _Server(body: '{"data": "not a map"}').start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      final error = await _errorOf(link, _request());

      expect(error, isA<HttpLinkParserException>());
      await link.dispose();
    });

    test('maps a cancelled request to CancelledException', () async {
      final server = await _Server(
        body: '{"data": {"viewer": {"id": "1"}}}',
        delay: const Duration(seconds: 2),
      ).start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      final token = CancellationToken();
      final future = link
          .request(_request(cancellationToken: token))
          .timeout(const Duration(seconds: 5))
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();

      await expectLater(future, throwsA(isA<CancelledException>()));
      token.dispose();
      await link.dispose();
    });

    test('reports a transport failure as a link exception', () async {
      final server = await _Server(
        delay: const Duration(seconds: 2),
      ).start();
      addTearDown(server.stop);

      final client = dio.Dio(
        dio.BaseOptions(
          connectTimeout: const Duration(milliseconds: 300),
          receiveTimeout: const Duration(milliseconds: 300),
        ),
      );
      final link = DioLink(server.url, client: client);
      final error = await _errorOf(link, _request());

      expect(error, isA<ServerException>());
      await link.dispose();
      client.close(force: true);
    });

    test('sends a multipart upload when variables carry an http.MultipartFile',
        () async {
      final server = await _Server(
        body: '{"data": {"uploadFile": {"id": "123", "filename": "test.txt"}}}',
      ).start();
      addTearDown(server.stop);

      final link = DioLink(server.url);
      final request = _request(
        source: 'mutation UploadFile(\$file: Upload!) {'
            ' uploadFile(file: \$file) { id filename } }',
        variables: {
          'file': http.MultipartFile.fromBytes(
            'variables.file',
            utf8.encode('Hello, World!'),
            filename: 'test.txt',
            contentType: MediaType('text', 'plain'),
          ),
        },
      );
      final response = await link.request(request).first;

      expect(response.data!['uploadFile']!['id'], '123');
      expect(server.sent, hasLength(1));
      final sent = server.sent.single;
      expect(sent.method, 'POST');
      expect(sent.headers['content-type'], startsWith('multipart/form-data'));
      expect(sent.body, contains('name="operations"'));
      expect(sent.body, contains('name="map"'));
      expect(sent.body, contains('filename="test.txt"'));
      await link.dispose();
    });

    test('carries the cookies CookieLink learned on the next request',
        () async {
      final server = await _Server(
        setCookies: const ['session=abc; Path=/'],
      ).start();
      addTearDown(server.stop);

      final link = Link.from([
        CookieLink(uri: Uri.parse(server.url)),
        DioLink(server.url),
      ]);

      await link.request(_request()).drain<void>();
      await link.request(_request()).drain<void>();

      expect(server.sent, hasLength(2));
      expect(server.sent.first.cookie, isNull);
      expect(server.sent.last.cookie, 'session=abc');
      await link.dispose();
    });

    test('sends the caller configuration through a shared Dio client',
        () async {
      final server = await _Server().start();
      addTearDown(server.stop);

      final client = dio.Dio(
        dio.BaseOptions(baseUrl: server.url, headers: const {'x-base': 'base'}),
      );
      final link = DioLink(server.url, client: client);
      await link.request(_request()).drain<void>();

      expect(server.sent, hasLength(1));
      expect(server.sent.single.headers['x-base'], 'base');
      await link.dispose();
    });
  });
}
