import 'dart:async';

/// Whether the host currently has network connectivity.
///
/// A host app implements this on top of whatever connectivity API it uses (for
/// example `connectivity_plus`), or drives a [ManualConnectivityMonitor]
/// itself. [OfflineMutationLink] reads [isOnline] for every request and listens
/// to [onConnectivityChanged] to replay the queue.
abstract class ConnectivityMonitor {
  /// Whether the client is online right now.
  ///
  /// This is the synchronous source of truth — a mutation is queued or sent
  /// based on this value, never on the last event seen.
  bool get isOnline;

  /// Emits `true`/`false` on every change of [isOnline].
  ///
  /// The current state is never emitted on listen.
  Stream<bool> get onConnectivityChanged;

  /// Release any resource held by the monitor.
  Future<void> dispose() async {}
}

/// A [ConnectivityMonitor] whose state is set by the host app.
///
/// Useful for hosts that already own a connectivity signal, and for tests.
class ManualConnectivityMonitor implements ConnectivityMonitor {
  ManualConnectivityMonitor({bool isOnline = true}) : _isOnline = isOnline;

  bool _isOnline;
  bool _disposed = false;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  bool get isOnline => _isOnline;

  @override
  Stream<bool> get onConnectivityChanged => _changes.stream;

  /// Set the current connectivity.
  ///
  /// Setting the state it already has is a no-op and emits nothing.
  void setOnline(bool online) {
    if (_disposed || _isOnline == online) {
      return;
    }
    _isOnline = online;
    _changes.add(online);
  }

  /// Report that connectivity is back.
  void goOnline() => setOnline(true);

  /// Report that connectivity is gone.
  void goOffline() => setOnline(false);

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _changes.close();
  }
}
