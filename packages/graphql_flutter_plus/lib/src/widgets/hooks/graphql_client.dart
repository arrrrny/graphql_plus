import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:graphql_plus/graphql_plus.dart';
import 'package:graphql_flutter_plus/src/widgets/graphql_provider.dart';

GraphQLClient useGraphQLClient() {
  final context = useContext();
  return useValueListenable(GraphQLProvider.of(context));
}
