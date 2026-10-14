import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/feedback.dart';

/// The ratings the device is holding for the service.
///
/// A rating made with no connection is stored on the device and sent when a
/// connection returns (`FEAT-010`, Edge Cases), so the queue outlives the
/// process. The interface is a seam, so the outbox can be exercised without a
/// platform channel and the iOS extension can run from its own empty store.
abstract interface class PendingFeedbackStore {
  /// Every held rating, oldest first.
  Future<List<PendingFeedback>> load();

  /// Writes [pending] as the whole queue.
  Future<void> save(List<PendingFeedback> pending);
}

/// Holds the queue on the device through `shared_preferences`.
///
/// The queue is stored as one JSON document under a single key. A document the
/// app cannot parse resolves empty rather than throwing: a queue the reader
/// cannot read is better started over than shown as a crash.
class SharedPreferencesPendingFeedbackStore implements PendingFeedbackStore {
  SharedPreferencesPendingFeedbackStore({
    SharedPreferencesAsync? preferencesOverride,
  }) : _preferences = preferencesOverride;

  static const String _pendingKey = 'feedback.pending';

  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync get _store =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<List<PendingFeedback>> load() async {
    final raw = await _store.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return <PendingFeedback>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <PendingFeedback>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PendingFeedback.fromStoredJson)
          .toList();
    } on FormatException {
      return <PendingFeedback>[];
    }
  }

  @override
  Future<void> save(List<PendingFeedback> pending) {
    final raw = jsonEncode(
      pending.map((item) => item.toStoredJson()).toList(growable: false),
    );
    return _store.setString(_pendingKey, raw);
  }
}

/// A queue kept only for the life of the process, for tests.
class InMemoryPendingFeedbackStore implements PendingFeedbackStore {
  InMemoryPendingFeedbackStore({
    List<PendingFeedback> seed = const <PendingFeedback>[],
  }) : _pending = List<PendingFeedback>.of(seed);

  final List<PendingFeedback> _pending;

  @override
  Future<List<PendingFeedback>> load() async =>
      List<PendingFeedback>.of(_pending);

  @override
  Future<void> save(List<PendingFeedback> pending) async {
    _pending
      ..clear()
      ..addAll(pending);
  }
}
