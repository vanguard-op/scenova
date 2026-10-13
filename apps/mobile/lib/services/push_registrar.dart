import 'dart:async';

import '../models/lookup.dart';
import 'connectivity.dart';
import 'push_registration_api.dart';
import 'push_tokens.dart';

/// Registers the device for a clip-ready notice (`C-008`).
///
/// When a generation runs past the wait threshold the reader is offered a
/// notice; taking it registers this device's push token so the notification
/// service can reach the reader when the clip is ready.
///
/// A registration that cannot be sent — the device dropped offline, or the
/// intake asked the client to slow down — is held and retried when the
/// connection returns, matching the app's offline rule that work which needs the
/// network is queued rather than lost. A rejected or unauthenticated
/// registration is dropped, since resending it unchanged cannot succeed.
class PushRegistrar {
  PushRegistrar({
    required this.api,
    required this.tokens,
    required this.connectivity,
  }) {
    _connectivitySub = connectivity.changes.listen((online) {
      if (online) unawaited(_flushPending());
    });
  }

  final PushRegistrationApi api;
  final PushTokenProvider tokens;
  final ConnectivityMonitor connectivity;

  late final StreamSubscription<bool> _connectivitySub;
  bool _pending = false;
  bool _disposed = false;

  /// Whether a registration is waiting for the connection to come back.
  bool get pendingRegistration => _pending;

  /// Registers this device for a clip-ready notice.
  ///
  /// Returns whether the token reached the service. A registration held for the
  /// connection, or refused because no token is available, returns false.
  Future<bool> requestClipReadyNotice() async {
    if (_disposed) return false;
    final token = await tokens.token();
    if (token == null || token.isEmpty) return false;
    if (!connectivity.isOnline) {
      _pending = true;
      return false;
    }
    try {
      await api.register(token: token, platform: LookupPlatform.current());
      _pending = false;
      return true;
    } on PushRegistrationException catch (error) {
      // An offline or rate-limited registration stays pending; a rejected or
      // unauthenticated one cannot be fixed by resending it.
      _pending = error.isOffline || error.isRetryable;
      return false;
    }
  }

  Future<void> _flushPending() async {
    if (!_pending || _disposed) return;
    await requestClipReadyNotice();
  }

  void dispose() {
    _disposed = true;
    unawaited(_connectivitySub.cancel());
  }
}
