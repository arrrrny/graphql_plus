import 'package:flutter_test/flutter_test.dart';
// The Material widgets are the point of these tests; the deprecation of
// `package:flutter/material.dart` (Flutter 3.47.0+) is an SDK-wide migration that
// is out of scope for a 5.x patch release.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'package:graphql_flutter_plus/src/widgets/graphql_consumer.dart'
    show GraphQLConsumer;

void main() {
  group('GraphQLConsumer', () {
    testWidgets('raises assertion error because of lack of GraphQLProvider',
        (WidgetTester tester) async {
      await tester.pumpWidget(const GraphQLConsumer(builder: _b));
      expect(tester.takeException(), isAssertionError);
    });
  });
}

Widget _b(_) => Container();
