/// Offline support: queue the mutations a client makes without connectivity and
/// replay them, in order, once it is back.
library;

export 'package:graphql_plus/src/offline/connectivity.dart';
export 'package:graphql_plus/src/offline/mutation_queue.dart';
export 'package:graphql_plus/src/offline/offline_mutation_link.dart';
