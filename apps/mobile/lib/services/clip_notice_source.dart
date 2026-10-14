import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../models/clip_notice.dart';
import 'firebase_client.dart';

/// The device's intake for the clip-ready notice (`C-008`).
///
/// The notification service pushes a notice to the device's token when a
/// lookup's generation finishes. The notice carries the clip, which the client
/// obtains from it — a phrase clip has no other delivery path (`FEAT-007`).
abstract interface class ClipNoticeSource {
  /// Every notice that reaches this device: one while the app is in the
  /// foreground, and one the reader opened while the app was away.
  Stream<ClipNotice> get notices;

  /// The notice the app was launched from, when it was opened by one.
  Future<ClipNotice?> openedFromNotice();

  void dispose();
}

/// The notices the platform's messaging service delivers.
///
/// The token registration (`C-008`) tells the notification service where to
/// send; this is the other half, where the notice arrives and the clip is
/// obtained from it. A message whose payload is not a notice is dropped rather
/// than surfaced, so nothing the reader sees depends on a message's shape.
class FirebaseClipNoticeSource implements ClipNoticeSource {
  FirebaseClipNoticeSource({
    FirebaseMessaging? messagingOverride,
    Future<FirebaseApp> Function()? initialize,
  }) : _messaging = messagingOverride,
       _initialize = initialize ?? initializeFirebaseClient {
    unawaited(_attach());
  }

  FirebaseMessaging? _messaging;
  final Future<FirebaseApp> Function() _initialize;
  final StreamController<ClipNotice> _controller =
      StreamController<ClipNotice>.broadcast();
  final List<StreamSubscription<RemoteMessage>> _subscriptions =
      <StreamSubscription<RemoteMessage>>[];
  Future<FirebaseMessaging>? _attaching;
  bool _disposed = false;

  @override
  Stream<ClipNotice> get notices => _controller.stream;

  Future<FirebaseMessaging> _messagingInstance() {
    final existing = _messaging;
    if (existing != null) return Future<FirebaseMessaging>.value(existing);
    return _attaching ??= _initialize().then(
      (_) => _messaging = FirebaseMessaging.instance,
    );
  }

  /// Subscribes to the messaging service's notice streams.
  ///
  /// The notice streams are the messaging client's own, so the source is
  /// attached to them once the client is up. A build with no messaging service
  /// reports no notices rather than failing: the reader loses only the offer,
  /// and every other surface still works.
  Future<void> _attach() async {
    try {
      await _messagingInstance();
      if (_disposed) return;
      _subscriptions
        ..add(FirebaseMessaging.onMessage.listen(_receive))
        ..add(FirebaseMessaging.onMessageOpenedApp.listen(_receive));
    } on Object {
      // No messaging service on the build, or the client could not start.
    }
  }

  void _receive(RemoteMessage message) {
    if (_disposed) return;
    final notice = ClipNotice.fromData(message.data);
    if (notice == null) return;
    _controller.add(notice);
  }

  @override
  Future<ClipNotice?> openedFromNotice() async {
    try {
      final messaging = await _messagingInstance();
      final message = await messaging.getInitialMessage();
      return message == null ? null : ClipNotice.fromData(message.data);
    } on Object {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    unawaited(_controller.close());
  }
}

/// A notice intake driven by hand, for tests and for a laptop run.
///
/// It lets a notice be delivered as the messaging service would deliver it, so
/// the clip-ready path is exercisable without a device or a push provider.
class ScriptedClipNoticeSource implements ClipNoticeSource {
  ScriptedClipNoticeSource({this.initialNotice});

  /// The notice the app is opened from, when a test simulates a launch from
  /// one.
  ClipNotice? initialNotice;

  final StreamController<ClipNotice> _controller =
      StreamController<ClipNotice>.broadcast();

  @override
  Stream<ClipNotice> get notices => _controller.stream;

  /// Delivers [notice] as the messaging service would.
  void deliver(ClipNotice notice) {
    if (_controller.isClosed) return;
    _controller.add(notice);
  }

  /// Delivers a raw notice payload, so a test can exercise the parsing too.
  void deliverData(Map<String, dynamic> data) {
    final notice = ClipNotice.fromData(data);
    if (notice != null) deliver(notice);
  }

  @override
  Future<ClipNotice?> openedFromNotice() async => initialNotice;

  @override
  void dispose() => unawaited(_controller.close());
}
