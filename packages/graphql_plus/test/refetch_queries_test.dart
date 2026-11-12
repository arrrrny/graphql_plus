import 'package:test/test.dart';
import 'package:mockito/mockito.dart';

import 'package:graphql_plus/graphql_plus.dart';
import 'package:gql/language.dart';

import './helpers.dart';

void main() {
  const mutation = r'''
    mutation AddStar {
      action: addStar(input: {starrableId: "r1"}) {
        starrable { __typename id viewerHasStarred }
      }
    }
  ''';

  const query = r'''
    query ReadRepo {
      viewer { __typename repositories { __typename nodes { __typename id name } } }
    }
  ''';

  final mutationData = <String, dynamic>{
    'action': {
      'starrable': {
        '__typename': 'Repository',
        'id': 'r1',
        'viewerHasStarred': true,
      },
    },
  };

  final queryData = <String, dynamic>{
    'viewer': {
      '__typename': 'User',
      'repositories': {
        '__typename': 'RepositoryConnection',
        'nodes': [
          {'__typename': 'Repository', 'id': 'q1', 'name': 'n'},
        ],
      },
    },
  };

  late MockLink link;
  late GraphQLClient client;

  setUp(() {
    link = MockLink();
    client = GraphQLClient(
      cache: getTestCache(),
      link: link,
    );
  });

  test(
      'refetchQueries are fetched on the network after a successful mutation (awaitRefetchQueries: true)',
      () async {
    when(link.request(any)).thenAnswer((invocation) {
      final request = invocation.positionalArguments.first as Request;
      // operationName is null unless set in options, so route on the document
      final isMutation = request.operation.document == parseString(mutation);
      return Stream.fromIterable(
        [
          Response(
            data: isMutation ? mutationData : queryData,
            response: <String, dynamic>{},
          ),
        ],
      );
    });

    final result = await client.mutate(
      MutationOptions(
        document: parseString(mutation),
        refetchQueries: [QueryOptions(document: parseString(query))],
        awaitRefetchQueries: true,
      ),
    );

    expect(result.hasException, isFalse);
    expect(result.data!['action']['starrable']['viewerHasStarred'], isTrue);

    final captured = verify(link.request(captureAny)).captured.cast<Request>();
    expect(captured.length, 2);
    expect(captured[0].operation.document, parseString(mutation));
    expect(captured[1].operation.document, parseString(query));
  });

  test('refetchQueries are fire-and-forget by default', () async {
    when(link.request(any)).thenAnswer((invocation) {
      final request = invocation.positionalArguments.first as Request;
      // operationName is null unless set in options, so route on the document
      final isMutation = request.operation.document == parseString(mutation);
      return Stream.fromIterable(
        [
          Response(
            data: isMutation ? mutationData : queryData,
            response: <String, dynamic>{},
          ),
        ],
      );
    });

    final result = await client.mutate(
      MutationOptions(
        document: parseString(mutation),
        refetchQueries: [QueryOptions(document: parseString(query))],
      ),
    );

    expect(result.data, isNotNull);

    // wait for the fire-and-forget refetch to reach the link
    var captured = <Request>[];
    for (var i = 0; i < 50; i++) {
      captured = verify(link.request(captureAny)).captured.cast<Request>();
      if (captured.length >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(captured.length, 2);
    expect(captured[1].operation.document, parseString(query));
  });

  test(
      'awaited refetch failures surface on the mutation future (awaitRefetchQueries: true)',
      () async {
    when(link.request(any)).thenAnswer((invocation) {
      final request = invocation.positionalArguments.first as Request;
      if (request.operation.document == parseString(mutation)) {
        return Stream.fromIterable(
          [Response(data: mutationData, response: <String, dynamic>{})],
        );
      }
      return Stream<Response>.error(
        OperationException(
            graphqlErrors: [const GraphQLError(message: 'refetch boom')]),
      );
    });

    await expectLater(
      client.mutate(
        MutationOptions(
          document: parseString(mutation),
          refetchQueries: [QueryOptions(document: parseString(query))],
          awaitRefetchQueries: true,
        ),
      ),
      throwsA(isA<OperationException>()),
    );

    final captured = verify(link.request(captureAny)).captured.cast<Request>();
    expect(captured.length, 2);
    expect(captured[0].operation.document, parseString(mutation));
    expect(captured[1].operation.document, parseString(query));
  });

  test('refetchQueries do not run when the mutation has an exception',
      () async {
    when(link.request(any)).thenAnswer((invocation) {
      final request = invocation.positionalArguments.first as Request;
      if (request.operation.document == parseString(mutation)) {
        return Stream<Response>.error(
          OperationException(
              graphqlErrors: [const GraphQLError(message: 'boom')]),
        );
      }
      return Stream.fromIterable(
        [Response(data: queryData, response: <String, dynamic>{})],
      );
    });

    final result = await client.mutate(
      MutationOptions(
        document: parseString(mutation),
        refetchQueries: [QueryOptions(document: parseString(query))],
        awaitRefetchQueries: true,
      ),
    );

    expect(result.hasException, isTrue);

    final captured = verify(link.request(captureAny)).captured.cast<Request>();
    expect(captured.length, 1);
    expect(captured[0].operation.document, parseString(mutation));
  });
}
