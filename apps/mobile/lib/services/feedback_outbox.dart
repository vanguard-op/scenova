import 'dart:async';
import 'dart:math';

import '../config.dart';
import '../models/feedback.dart';
import 'connectivity.dart';
import 'feedback_api.dart';
import 'feedback_store.dart';

/// A fresh idempotency key for a rating: sixteen random bytes, hex-encoded.
///
/// It carries nothing about the reader, and two keys colliding is what the
/// contract's key is there to prevent (`C-012`, `clientFeedbackId`).
String newFeedbackId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// Delivers the reader's clip ratings to the feedback intake (`C-012`).
///
/// The outbox owns the client half of "Offline Behavior": a rating made with no
/// connection is stored on the device and sent when a connection returns
/// (`FEAT-010`, Edge Cases; `docs/Scenova/user-flow.md` → Flow 4, Alternate
/// Path B). Each rating carries the idempotency key it was minted with, so a
/// rating that reaches the service twice is recorded once.
///
/// Only the reader's latest rating of a clip counts (`C-012`), so a rating that
/// has not gone out yet is replaced rather than sent beside the one it replaces.
class FeedbackOutbox {
  FeedbackOutbox({
    required this.api,
    required this.store,
    required this.connectivity,
    this.queueLimit = AppConfig.feedbackQueueLimit,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _newId = newId ?? newFeedbackId,
       _clock = clock ?? DateTime.now {
    // The monitor's stream opens with the current value; only a connection that
    // comes back is a reason to send, so the first emission is not a flush.
    var opened = false;
    _connectivitySub = connectivity.changes.listen((online) {
      if (!opened) {
        opened = true;
        return;
      }
      if (online) unawaited(flush());
    });
  }

  final FeedbackApi api;
  final PendingFeedbackStore store;
  final ConnectivityMonitor connectivity;

  /// A bound on the held queue, so a long offline stretch cannot grow it
  /// without limit. This is backpressure, not a drop of the latest rating.
  final int queueLimit;

  final String Function() _newId;
  final DateTime Function() _clock;

  final List<PendingFeedback> _pending = <PendingFeedback>[];
  late final StreamSubscription<bool> _connectivitySub;

  bool _loaded = false;
  bool _disposed = false;

  /// Serialises submit and flush, so a rating is never sent twice by two paths
  /// at once and the queue cannot be rewritten from under a send.
  Future<void> _gate = Future<void>.value();

  /// The ratings held for the service, oldest first.
  List<PendingFeedback> get pending =>
      List<PendingFeedback>.unmodifiable(_pending);

  int get pendingCount => _pending.length;

  /// Records the reader's rating and tries to deliver it.
  ///
  /// Returns [FeedbackDelivery.recorded] when the service took it,
  /// [FeedbackDelivery.queued] when it is held for the connection to return, and
  /// [FeedbackDelivery.failed] when it could not be recorded. A rating the
  /// service may still take stays in the queue; one it refused is dropped.
  Future<FeedbackDelivery> submit({
    required String lookupId,
    required ClipRating rating,
  }) {
    return _withGate(() async {
      await _ensureLoaded();
      _pending.removeWhere((item) => item.lookupId == lookupId);
      final item = PendingFeedback(
        lookupId: lookupId,
        rating: rating,
        clientFeedbackId: _newId(),
        createdAt: _clock().toUtc(),
      );
      _pending.add(item);
      _trim();
      await _persist();
      if (!connectivity.isOnline) return FeedbackDelivery.queued;
      return _send(item);
    });
  }

  /// Sends everything held, oldest first.
  ///
  /// It stops at the first rating the service could not take, so the queue keeps
  /// its order; a rating the service refused outright is dropped, since
  /// resending it cannot succeed (`C-012`).
  Future<void> flush() {
    return _withGate(() async {
      await _ensureLoaded();
      if (_disposed || !connectivity.isOnline || _pending.isEmpty) return;
      for (final item in List<PendingFeedback>.of(_pending)) {
        try {
          await api.rate(item);
          _pending.remove(item);
          await _persist();
        } on FeedbackApiException catch (error) {
          if (error.isRetryable || error.isOffline) return;
          _pending.remove(item);
          await _persist();
        }
      }
    });
  }

  /// Sends one rating, keeping it when it may still go out.
  Future<FeedbackDelivery> _send(PendingFeedback item) async {
    try {
      await api.rate(item);
      _pending.remove(item);
      await _persist();
      return FeedbackDelivery.recorded;
    } on FeedbackApiException catch (error) {
      if (error.isOffline) return FeedbackDelivery.queued;
      if (error.isRetryable) return FeedbackDelivery.failed;
      // The rating was refused: resending it cannot succeed, so it is not kept.
      _pending.remove(item);
      await _persist();
      return FeedbackDelivery.failed;
    }
  }

  /// Reads the held queue once, on first use.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    List<PendingFeedback> stored;
    try {
      stored = await store.load();
    } on Object {
      // A queue the device cannot read starts empty rather than failing the
      // send; the reader's next rating is still kept.
      stored = const <PendingFeedback>[];
    }
    if (_disposed) return;
    _pending
      ..clear()
      ..addAll(stored);
    _trim();
  }

  void _trim() {
    if (_pending.length <= queueLimit) return;
    _pending.removeRange(0, _pending.length - queueLimit);
  }

  Future<void> _persist() async {
    try {
      await store.save(List<PendingFeedback>.of(_pending));
    } on Object {
      // A queue the device refuses to write is still held for this session; the
      // reader's rating must not surface as an unhandled error.
    }
  }

  Future<T> _withGate<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _gate = _gate.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  void dispose() {
    _disposed = true;
    unawaited(_connectivitySub.cancel());
  }
}
