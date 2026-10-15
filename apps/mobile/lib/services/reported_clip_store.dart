import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The lookups whose clips the reader reported and whose regenerated clip the
/// device is still waiting on (`FEAT-011`).
///
/// A report regenerates one clip for the reporting reader, and it reaches them
/// by the clip-ready notice (`C-008`), so the device has to remember which
/// lookups it reported until that notice arrives. The set is kept on the device
/// so the replacement survives a relaunch, including one the notice itself
/// opens the app for.
abstract interface class ReportedClipStore {
  /// The lookups awaiting a regenerated clip.
  Future<Set<String>> load();

  /// Writes [lookupIds] as the whole set.
  Future<void> save(Set<String> lookupIds);
}

/// Holds the set on the device through `shared_preferences`.
///
/// The set is stored as one JSON array under a single key. A document the app
/// cannot parse resolves empty rather than throwing: a set the reader cannot
/// read is better started over than shown as a crash.
class SharedPreferencesReportedClipStore implements ReportedClipStore {
  SharedPreferencesReportedClipStore({
    SharedPreferencesAsync? preferencesOverride,
  }) : _preferences = preferencesOverride;

  static const String _awaitingKey = 'report.awaiting_clip';

  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync get _store =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<Set<String>> load() async {
    final raw = await _store.getString(_awaitingKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded
          .whereType<String>()
          .where((lookupId) => lookupId.isNotEmpty)
          .toSet();
    } on FormatException {
      return <String>{};
    }
  }

  @override
  Future<void> save(Set<String> lookupIds) {
    final raw = jsonEncode(lookupIds.toList(growable: false));
    return _store.setString(_awaitingKey, raw);
  }
}

/// A set kept only for the life of the process, for tests.
class InMemoryReportedClipStore implements ReportedClipStore {
  InMemoryReportedClipStore({Set<String> seed = const <String>{}})
    : _lookupIds = Set<String>.of(seed);

  final Set<String> _lookupIds;

  @override
  Future<Set<String>> load() async => Set<String>.of(_lookupIds);

  @override
  Future<void> save(Set<String> lookupIds) async {
    _lookupIds
      ..clear()
      ..addAll(lookupIds);
  }
}
