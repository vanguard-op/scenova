import 'dart:async';
import 'dart:math';

import '../config.dart';
import '../models/report.dart';
import 'connectivity.dart';
import 'report_api.dart';
import 'report_store.dart';

/// A fresh idempotency key for a report: sixteen random bytes, hex-encoded.
///
/// It carries nothing about the reader, and two keys colliding is what the
/// contract's key is there to prevent (`C-013`, `clientReportId`).
String newReportId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// Delivers the reader's clip reports to the report intake (`C-013`).
///
/// The outbox owns the client half of "Offline Behavior": a report made with no
/// connection is stored on the device and sent when a connection returns
/// (`FEAT-011`, Edge Cases; `docs/Scenova/user-flow.md` → Flow 4, Alternate
/// Path B). Each report carries the idempotency key it was minted with, so a
/// report that reaches the service twice is recorded once.
///
/// A report queues the entry for review and holds it from new readers, and the
/// same reader has already reported an entry once their first report reaches
/// the service (`C-013`). So only one report per lookup is held: a later report
/// of the same clip replaces the one still waiting rather than being sent beside
/// it.
class ReportOutbox {
  ReportOutbox({
    required this.api,
    required this.store,
    required this.connectivity,
    this.queueLimit = AppConfig.reportQueueLimit,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _newId = newId ?? newReportId,
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

  final ReportApi api;
  final PendingReportStore store;
  final ConnectivityMonitor connectivity;

  /// A bound on the held queue, so a long offline stretch cannot grow it
  /// without limit. This is backpressure, not a drop of the latest report.
  final int queueLimit;

  final String Function() _newId;
  final DateTime Function() _clock;

  final List<PendingReport> _pending = <PendingReport>[];
  late final StreamSubscription<bool> _connectivitySub;

  bool _loaded = false;
  bool _disposed = false;

  /// Serialises submit and flush, so a report is never sent twice by two paths
  /// at once and the queue cannot be rewritten from under a send.
  Future<void> _gate = Future<void>.value();

  /// The reports held for the service, oldest first.
  List<PendingReport> get pending => List<PendingReport>.unmodifiable(_pending);

  int get pendingCount => _pending.length;

  /// Records the reader's report and tries to deliver it.
  ///
  /// Returns [ReportDelivery.sent] when the service queued it,
  /// [ReportDelivery.queued] when it is held for the connection to return,
  /// [ReportDelivery.duplicate] when the reader had already reported this clip,
  /// and [ReportDelivery.failed] when it could not be sent. A report the service
  /// may still take stays in the queue; one it refused or already holds is
  /// dropped.
  Future<ReportDelivery> submit({
    required String lookupId,
    required ReportReason reason,
    String? note,
  }) {
    return _withGate(() async {
      await _ensureLoaded();
      _pending.removeWhere((item) => item.lookupId == lookupId);
      final item = PendingReport(
        lookupId: lookupId,
        reason: reason,
        note: note,
        clientReportId: _newId(),
        createdAt: _clock().toUtc(),
      );
      _pending.add(item);
      _trim();
      await _persist();
      if (!connectivity.isOnline) return ReportDelivery.queued;
      return _send(item);
    });
  }

  /// Sends everything held, oldest first.
  ///
  /// It stops at the first report the service could not take, so the queue keeps
  /// its order; a report the service refused or already holds is dropped, since
  /// resending it cannot succeed (`C-013`).
  Future<void> flush() {
    return _withGate(() async {
      await _ensureLoaded();
      if (_disposed || !connectivity.isOnline || _pending.isEmpty) return;
      for (final item in List<PendingReport>.of(_pending)) {
        try {
          await api.report(item);
          _pending.remove(item);
          await _persist();
        } on ReportApiException catch (error) {
          if (error.isRetryable || error.isOffline) return;
          _pending.remove(item);
          await _persist();
        }
      }
    });
  }

  /// Sends one report, keeping it when it may still go out.
  Future<ReportDelivery> _send(PendingReport item) async {
    try {
      await api.report(item);
      _pending.remove(item);
      await _persist();
      return ReportDelivery.sent;
    } on ReportApiException catch (error) {
      if (error.isOffline) return ReportDelivery.queued;
      if (error.isDuplicate) {
        // The service already holds this reader's report for the clip, so the
        // one on the device is not sent beside it.
        _pending.remove(item);
        await _persist();
        return ReportDelivery.duplicate;
      }
      if (error.isRetryable) return ReportDelivery.failed;
      // The report was refused: resending it cannot succeed, so it is not kept.
      _pending.remove(item);
      await _persist();
      return ReportDelivery.failed;
    }
  }

  /// Reads the held queue once, on first use.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    List<PendingReport> stored;
    try {
      stored = await store.load();
    } on Object {
      // A queue the device cannot read starts empty rather than failing the
      // send; the reader's next report is still kept.
      stored = const <PendingReport>[];
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
      await store.save(List<PendingReport>.of(_pending));
    } on Object {
      // A queue the device refuses to write is still held for this session; the
      // reader's report must not surface as an unhandled error.
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
