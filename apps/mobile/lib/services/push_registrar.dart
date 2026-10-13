import 'dart:async';

import '../models/lookup.dart';
import 'connectivity.dart';
import 'push_registration_api.dart';
import 'push_tokens.dart';

/// What came of a request for a clip-ready notice (`C-008`).
enum PushNoticeResult {
  /// The service recorded the device; a notice will come when the clip is ready.
  registered,

  /// The service reports no notice is coming: the lookup has already finished,
  /// so the view will settle on its own.
  noNoticeNeeded,

  /// The registration did not reach the service, or was refused. A registration
  /// held for the connection is retried when it returns.
  notRegistered,
}

/// Registers the device for a clip-ready notice (`C-008`).
///
/// When a generation runs past the wait threshold the reader is offered a
/// notice; taking it registers this device's push token against the lookup it
/// is waiting on, so the notification service can find its way back to the
/// reader when that clip is ready.
///
/// A registration that cannot be sent — the device dropped offline, or the
/// intake asked the client to slow down — is held, with its lookup, and retried
/// when the connection returns, matching the app's offline rule that work which
/// needs the network is queued rather than lost. A rejected or unauthenticated
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

  /// The lookup a held registration is waiting to send, or null when none is
  /// held.
  String? _pendingLookupId;
  bool _disposed = false;

  /// Whether a registration is waiting for the connection to come back.
  bool get pendingRegistration => _pendingLookupId != null;

  /// Registers this device for a clip-ready notice about [lookupId].
  ///
  /// Returns whether a notice will come. A registration held for the connection,
  /// or refused because no token is available, reports [PushNoticeResult
  /// .notRegistered]; a lookup the service has already finished reports
  /// [PushNoticeResult.noNoticeNeeded].
  Future<PushNoticeResult> requestClipReadyNotice({
    required String lookupId,
  }) async {
    if (_disposed) return PushNoticeResult.notRegistered;
    final token = await tokens.token();
    if (token == null || token.isEmpty) return PushNoticeResult.notRegistered;
    if (!connectivity.isOnline) {
      _pendingLookupId = lookupId;
      return PushNoticeResult.notRegistered;
    }
    try {
      final registered = await api.register(
        token: token,
        platform: LookupPlatform.current(),
        lookupId: lookupId,
      );
      _pendingLookupId = null;
      return registered
          ? PushNoticeResult.registered
          : PushNoticeResult.noNoticeNeeded;
    } on PushRegistrationException catch (error) {
      // An offline or rate-limited registration stays pending; a rejected or
      // unauthenticated one cannot be fixed by resending it.
      _pendingLookupId = (error.isOffline || error.isRetryable)
          ? lookupId
          : null;
      return PushNoticeResult.notRegistered;
    }
  }

  Future<void> _flushPending() async {
    final lookupId = _pendingLookupId;
    if (lookupId == null || _disposed) return;
    await requestClipReadyNotice(lookupId: lookupId);
  }

  void dispose() {
    _disposed = true;
    unawaited(_connectivitySub.cancel());
  }
}
