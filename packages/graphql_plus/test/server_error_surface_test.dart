import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';

import 'package:graphql_plus/graphql_plus.dart';
import 'package:gql/language.dart';

import './helpers.dart';

/// Regression proof for upstream #877 (fork issue #4):
/// a non-GraphQL server error body (e.g. HTTP 500 `{"message": "..."}`)
/// must stay reachable on the QueryResult via HttpLinkServerException.
void main() {
  const query = r'''
    query ReadRepo {
      viewer { __typename id }
    }
  ''';

  late MockLink link;
  late GraphQLClient client;

  setUp(() {
    link = MockLink();
    client = GraphQLClient(
      cache: getTestCache(),
      link: link,
    );
  });

  test('HTTP 500 with a non-GraphQL body surfaces the raw body and status code',
      () async {
    const rawBody = '{"message":"Internal Server Error"}';

    when(link.request(any)).thenAnswer(
      (_) => Stream<Response>.error(
        HttpLinkServerException(
          response: http.Response(
            rawBody,
            500,
          ),
          parsedResponse: Response(
            response: <String, dynamic>{'message': 'Internal Server Error'},
          ),
          statusCode: 500,
        ),
      ),
    );

    final result = await client.query(
      QueryOptions(document: parseString(query)),
    );

    expect(result.hasException, isTrue);

    final linkException = result.exception!.linkException;
    expect(linkException, isA<HttpLinkServerException>());

    final httpException = linkException as HttpLinkServerException;
    // the server's error message is NOT lost — it rides the raw response
    expect(httpException.response.body, rawBody);
    expect(httpException.statusCode, 500);
    // the parsed GraphQL view (data/errors) is legitimately empty
    expect(httpException.parsedResponse?.data, isNull);
    expect(httpException.parsedResponse?.errors, isNull);
  });

  test('end-to-end: real CancellableHttpLink surfaces raw 500 body', () async {
    const rawBody = '{"message":"Internal Server Error"}';
    final server = await HttpServer.bind('localhost', 0);
    server.listen((rq) async {
      rq.response.statusCode = 500;
      rq.response.headers.contentType = ContentType.json;
      rq.response.write(rawBody);
      await rq.response.close();
    });

    try {
      final link =
          CancellableHttpLink('http://localhost:${server.port}/graphql');
      final client = GraphQLClient(cache: getTestCache(), link: link);

      try {
        final result = await client.query(
          QueryOptions(
            document: parseString(query),
            fetchPolicy: FetchPolicy.networkOnly,
          ),
        );

        expect(result.hasException, isTrue);

        // the construction half: a real HTTP 500 with a non-GraphQL body
        // *becomes* an HttpLinkServerException carrying the raw response
        final httpException =
            result.exception!.linkException as HttpLinkServerException;
        expect(httpException.response.body, rawBody);
        expect(httpException.statusCode, 500);
      } finally {
        await link.dispose();
      }
    } finally {
      await server.close(force: true);
    }
  });
}
