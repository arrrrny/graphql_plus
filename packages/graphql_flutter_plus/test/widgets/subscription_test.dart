import 'dart:io';

// The Material widgets are the point of these tests; the deprecation of
// `package:flutter/material.dart` (Flutter 3.47.0+) is an SDK-wide migration that
// is out of scope for a 5.x patch release.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, MethodCall;
import 'package:flutter_test/flutter_test.dart';

import 'package:graphql_flutter_plus/graphql_flutter_plus.dart';
import 'package:http/http.dart' as http;
import 'package:mockito/mockito.dart';

class MockHttpClient extends Mock implements http.Client {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest? request) =>
      super.noSuchMethod(
        Invocation.method(#send, [request]),
        returnValue: Future.value(
          http.StreamedResponse(
            Stream.fromIterable(const [<int>[]]),
            500,
          ),
        ),
      ) as Future<http.StreamedResponse>;
}

final query = gql("""
  subscription Foo {
    foo
  }
""");

/// https://flutter.dev/docs/cookbook/persistence/reading-writing-files#testing
Future<void> mockApplicationDocumentsDirectory() async {
  // Create a temporary directory.
  final directory = await Directory.systemTemp.createTemp();
  final handler = (MethodCall methodCall) async {
    // If you're getting the apps documents directory, return the path to the
    // temp directory on the test environment instead.
    if (methodCall.method == 'getApplicationDocumentsDirectory') {
      return directory.path;
    }
    return null;
  };

  // Mock out the MethodChannel for the path_provider plugin.
  final channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, handler);
  final channel_osx = MethodChannel('plugins.flutter.io/path_provider_macos');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel_osx, handler);
}

class Page extends StatelessWidget {
  Page({
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Subscription(
      options: SubscriptionOptions(
        document: query,
      ),
      builder: (QueryResult result, {Refetch? refetch, FetchMore? fetchMore}) =>
          Container(),
    );
  }
}

void main() {
  setUpAll(() async {
    await mockApplicationDocumentsDirectory();
    await initHiveForFlutter();
  });

  group('Subscription', () {
    late MockHttpClient mockHttpClient;
    HttpLink httpLink;
    ValueNotifier<GraphQLClient>? client;

    setUp(() async {
      mockHttpClient = MockHttpClient();
      httpLink = HttpLink(
        'https://unused/graphql',
        httpClient: mockHttpClient,
      );
      client = ValueNotifier(
        GraphQLClient(
          cache: GraphQLCache(store: await HiveStore.open()),
          link: httpLink,
        ),
      );
    });

    testWidgets('works', (WidgetTester tester) async {
      final page = Page();

      await tester.pumpWidget(GraphQLProvider(
        client: client,
        child: page,
      ));

      verify(
        mockHttpClient.send(
          argThat(isA<http.Request>()
              .having((request) => request.method, "method", "POST")
              .having((request) => request.headers, "headers", isNotNull)
              .having((request) => request.body, "body", isNotNull)
              .having(
                (request) => request.url,
                "expected endpoint",
                Uri.parse('https://unused/graphql'),
              )),
        ),
      ).called(1);
      await tester.pump();
      verifyNoMoreInteractions(mockHttpClient);
    });
  });
}
