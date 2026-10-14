import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/report.dart';

/// The reports the device is holding for the service.
///
/// A report made with no connection is stored on the device and sent when a
/// connection returns (`FEAT-011`, Edge Cases), so the queue outlives the
/// process. The interface is a seam, so the outbox can be exercised without a
/// platform channel.
abstract interface class PendingReportStore {
  /// Every held report, oldest first.
  Future<List<PendingReport>> load();

  /// Writes [pending] as the whole queue.
  Future<void> save(List<PendingReport> pending);
}

/// Holds the queue on the device through `shared_preferences`.
///
/// The queue is stored as one JSON document under a single key. A document the
/// app cannot parse resolves empty rather than throwing: a queue the reader
/// cannot read is better started over than shown as a crash.
class SharedPreferencesPendingReportStore implements PendingReportStore {
  SharedPreferencesPendingReportStore({
    SharedPreferencesAsync? preferencesOverride,
  }) : _preferences = preferencesOverride;

  static const String _pendingKey = 'report.pending';

  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync get _store =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<List<PendingReport>> load() async {
    final raw = await _store.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return <PendingReport>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <PendingReport>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PendingReport.fromStoredJson)
          .toList();
    } on FormatException {
      return <PendingReport>[];
    }
  }

  @override
  Future<void> save(List<PendingReport> pending) {
    final raw = jsonEncode(
      pending.map((item) => item.toStoredJson()).toList(growable: false),
    );
    return _store.setString(_pendingKey, raw);
  }
}

/// A queue kept only for the life of the process, for tests.
class InMemoryPendingReportStore implements PendingReportStore {
  InMemoryPendingReportStore({
    List<PendingReport> seed = const <PendingReport>[],
  }) : _pending = List<PendingReport>.of(seed);

  final List<PendingReport> _pending;

  @override
  Future<List<PendingReport>> load() async => List<PendingReport>.of(_pending);

  @override
  Future<void> save(List<PendingReport> pending) async {
    _pending
      ..clear()
      ..addAll(pending);
  }
}
