import 'package:graphql_plus/src/cache/store.dart';

/// Web fallback for [IsolateStore]: `dart:isolate` does not exist there.
///
/// Throws [UnsupportedError] on construction and on every mutation rather than
/// quietly degrading to a UI-thread store, so a caller that asked for
/// background persistence learns it did not get it. [close] is a no-op: there
/// is no worker to shut down.
class IsolateStore extends Store {
  IsolateStore._();

  static const _unsupported =
      'IsolateStore requires dart:isolate, which is not available on the web';

  /// See [IsolateStore.memory] on the VM implementation.
  static Future<IsolateStore> memory() async =>
      throw UnsupportedError(_unsupported);

  /// See [IsolateStore.hive] on the VM implementation.
  static Future<IsolateStore> hive({
    required String boxName,
    String? path,
  }) async =>
      throw UnsupportedError(_unsupported);

  /// See [IsolateStore.flush] on the VM implementation.
  Future<void> flush() async => throw UnsupportedError(_unsupported);

  /// See [IsolateStore.close] on the VM implementation.
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(_unsupported);
}
