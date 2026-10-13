import 'dart:async';

/// Whether the device has a connection.
///
/// The offline rules are product behaviour, not a platform detail
/// (`docs/Scenova/user-flow.md` → "Offline Behavior"): history and saved clips
/// are served with no connection, a new lookup shows an offline message, and
/// feedback and reports queue for reconnection.
///
/// The platform monitor is a shared dependency the app does not yet declare;
/// this interface is the seam for it.
abstract interface class ConnectivityMonitor {
  bool get isOnline;

  /// Emits on every change, starting with the current value.
  Stream<bool> get changes;

  void dispose();
}

/// A monitor driven by hand, for tests and for the development build.
class ManualConnectivity implements ConnectivityMonitor {
  ManualConnectivity({bool online = true}) {
    _online = online;
  }

  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  bool _online = true;

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get changes async* {
    yield _online;
    yield* _controller.stream;
  }

  void setOnline(bool value) {
    if (_online == value) return;
    _online = value;
    _controller.add(value);
  }

  @override
  void dispose() => _controller.close();
}
