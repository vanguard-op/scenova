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

  /// The reader refused notifications, so no notice can be shown. The platform
  /// will ask again the next time they take the offer.
  notificationsDenied,

  /// The reader refused notifications and the platform will not ask again; the
  /// choice has to be changed in the device's settings.
  notificationsPermanentlyDenied,

  /// The registration did not reach the service, or the device had no token to
  /// send. A registration held for the connection is retried when it returns.
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
/// registration is dropped, since resending it unchanged cannot succeed. A
/// reader who refuses the notification permission is reported as a refusal and
/// holds nothing: there is no later event for a device that cannot be reached.
///
/// The registration can go out without raising the prompt: a phrase lookup
/// takes that route, since its clip reaches the device only by the notice and
/// the device has to be registered before generation finishes (`FEAT-007`).
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

  /// Whether the held registration may raise the notification prompt when it is
  /// retried. A registration that went out without asking the reader stays
  /// that way, so a reconnection never prompts on its own.
  bool _pendingPrompt = true;
  bool _disposed = false;

  /// Whether a registration is waiting for the connection to come back.
  bool get pendingRegistration => _pendingLookupId != null;

  /// Registers this device for a clip-ready notice about [lookupId].
  ///
  /// Returns whether a notice will come. A registration held for the connection,
  /// or one that could not take a token, reports [PushNoticeResult
  /// .notRegistered]; a lookup the service has already finished reports
  /// [PushNoticeResult.noNoticeNeeded]; a reader who refused the permission is
  /// reported as the refusal it is, so the app can say so plainly.
  ///
  /// [prompt] raises the platform's notification prompt when the reader has not
  /// answered it yet; the notify offer passes it, so the prompt arrives with the
  /// reader's own intent behind it. A phrase lookup passes `false`, because its
  /// clip has no other delivery path than the notice and the device has to be
  /// registered before generation finishes (`FEAT-007`).
  Future<PushNoticeResult> requestClipReadyNotice({
    required String lookupId,
    bool prompt = true,
  }) async {
    if (_disposed) return PushNoticeResult.notRegistered;
    final outcome = prompt ? await tokens.request() : await tokens.current();
    if (outcome is PushTokenRefused) {
      // A refusal is not a connectivity problem: nothing is held for the
      // connection, and the reader is told what actually happened.
      return outcome.permanently
          ? PushNoticeResult.notificationsPermanentlyDenied
          : PushNoticeResult.notificationsDenied;
    }
    if (outcome is! PushTokenIssued) return PushNoticeResult.notRegistered;
    final token = outcome.token;
    if (!connectivity.isOnline) {
      _hold(lookupId, prompt: prompt);
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
      final retryable = error.isOffline || error.isRetryable;
      if (retryable) {
        _hold(lookupId, prompt: prompt);
      } else {
        _pendingLookupId = null;
      }
      return PushNoticeResult.notRegistered;
    }
  }

  void _hold(String lookupId, {required bool prompt}) {
    _pendingLookupId = lookupId;
    _pendingPrompt = prompt;
  }

  Future<void> _flushPending() async {
    final lookupId = _pendingLookupId;
    if (lookupId == null || _disposed) return;
    await requestClipReadyNotice(lookupId: lookupId, prompt: _pendingPrompt);
  }

  void dispose() {
    _disposed = true;
    unawaited(_connectivitySub.cancel());
  }
}
