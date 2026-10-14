import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_entry.dart';

/// The Free tier's history cap.
///
/// History keeps the most recent lookups and older ones drop off
/// (`docs/Scenova/screens/06-history.md` → Edge Cases). The device store holds
/// the cap so a very large history cannot grow without bound; a later tier can
/// raise it.
const int kFreeTierHistoryCapacity = 50;

/// How much room the device has left for saved lookups.
enum HistoryStorageState {
  /// A lookup can still be saved.
  ok,

  /// The device cannot take another lookup. The reader is warned and can free
  /// room by clearing history (`FEAT-009` → Edge Cases).
  full,
}

/// The device's lookup history.
///
/// History is on the device only and never leaves it
/// (`docs/Scenova/nfr.md` → "Data lifecycle"). The durable implementation
/// persists the reader's lookups so they survive a relaunch and replay offline;
/// the in-memory implementation stands in for tests and for the iOS extension's
/// own process.
abstract interface class HistoryStore {
  /// The most recent lookups, newest first.
  Future<List<HistoryEntry>> recent({int limit = 5});

  /// Every saved lookup, newest first.
  Future<List<HistoryEntry>> all();

  /// Saves a lookup, replacing any earlier entry for the same word and phrase.
  Future<void> save(HistoryEntry entry);

  Future<void> remove(String id);

  Future<void> clear();

  /// The room left on the device for saved lookups.
  ///
  /// A store that could not write reports [HistoryStorageState.full] until a
  /// later write or a clear succeeds, so the reader can be told and can free
  /// room.
  Future<HistoryStorageState> storageState();
}

/// The reader's lookups, kept on the device through `shared_preferences`.
///
/// The entries are stored as one JSON document under a single key. A read of a
/// document the app cannot parse resolves empty rather than throwing: a history
/// the reader cannot read is better shown as empty than as a crash, and the next
/// save overwrites it.
class SharedPreferencesHistoryStore implements HistoryStore {
  SharedPreferencesHistoryStore({
    SharedPreferencesAsync? preferencesOverride,
    this.capacity = kFreeTierHistoryCapacity,
  }) : _preferences = preferencesOverride;

  static const String _entriesKey = 'history.entries';

  /// The most lookups the device keeps; older ones drop off.
  final int capacity;

  SharedPreferencesAsync? _preferences;

  /// Whether the last write failed, so the store reports the device full.
  bool _writeFailed = false;

  /// Serialises read-modify-write cycles, so two saves that overlap cannot lose
  /// one another's entry.
  Future<void> _pending = Future<void>.value();

  SharedPreferencesAsync get _store =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<List<HistoryEntry>> all() async {
    final entries = await _read();
    entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return entries;
  }

  @override
  Future<List<HistoryEntry>> recent({int limit = 5}) async {
    final ordered = await all();
    return ordered.take(limit).toList(growable: false);
  }

  @override
  Future<void> save(HistoryEntry entry) => _mutate((entries) {
    entries.removeWhere(
      (existing) =>
          existing.word == entry.word && existing.phrase == entry.phrase,
    );
    entries.add(entry);
    return entries;
  });

  @override
  Future<void> remove(String id) =>
      _mutate((entries) => entries..removeWhere((entry) => entry.id == id));

  @override
  Future<void> clear() => _mutate((entries) => entries..clear());

  @override
  Future<HistoryStorageState> storageState() async =>
      _writeFailed ? HistoryStorageState.full : HistoryStorageState.ok;

  /// Applies [change] to the stored entries and writes them back.
  ///
  /// A write the device refuses is recorded rather than thrown: the reader's
  /// lookup must not surface as an unhandled error, and the warning belongs on
  /// the surface that can offer to free room.
  Future<void> _mutate(
    List<HistoryEntry> Function(List<HistoryEntry> entries) change,
  ) {
    final result = _pending.then((_) async {
      final entries = change(await _read());
      final trimmed = entries.length > capacity
          ? (entries..sort((a, b) => b.savedAt.compareTo(a.savedAt)))
                .take(capacity)
                .toList(growable: false)
          : entries;
      try {
        await _write(trimmed);
        _writeFailed = false;
      } on Object {
        _writeFailed = true;
      }
    });
    _pending = result.catchError((Object _) {});
    return _pending;
  }

  Future<List<HistoryEntry>> _read() async {
    final raw = await _store.getString(_entriesKey);
    if (raw == null || raw.isEmpty) return <HistoryEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <HistoryEntry>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(HistoryEntry.fromJson)
          .toList();
    } on FormatException {
      return <HistoryEntry>[];
    }
  }

  Future<void> _write(List<HistoryEntry> entries) {
    final raw = jsonEncode(
      entries.map((entry) => entry.toJson()).toList(growable: false),
    );
    return _store.setString(_entriesKey, raw);
  }
}

/// A history kept only for the life of the process.
///
/// For tests, and for the iOS extension, which runs in its own process and
/// starts from the same defaults as a fresh app.
class InMemoryHistoryStore implements HistoryStore {
  InMemoryHistoryStore({
    List<HistoryEntry> seed = const <HistoryEntry>[],
    this.capacity = kFreeTierHistoryCapacity,
    this.storageFull = false,
  }) : _entries = List<HistoryEntry>.of(seed);

  final List<HistoryEntry> _entries;

  /// The most lookups the device keeps; older ones drop off.
  final int capacity;

  /// Whether the device is out of room, so a test can view the warning.
  bool storageFull;

  @override
  Future<List<HistoryEntry>> recent({int limit = 5}) async {
    final ordered = await all();
    return ordered.take(limit).toList(growable: false);
  }

  @override
  Future<List<HistoryEntry>> all() async {
    final ordered = List<HistoryEntry>.of(_entries)
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return ordered;
  }

  @override
  Future<void> save(HistoryEntry entry) async {
    if (storageFull) return;
    _entries.removeWhere(
      (existing) =>
          existing.word == entry.word && existing.phrase == entry.phrase,
    );
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      _entries.removeRange(capacity, _entries.length);
    }
  }

  @override
  Future<void> remove(String id) async {
    _entries.removeWhere((entry) => entry.id == id);
  }

  @override
  Future<void> clear() async {
    _entries.clear();
    storageFull = false;
  }

  @override
  Future<HistoryStorageState> storageState() async =>
      storageFull ? HistoryStorageState.full : HistoryStorageState.ok;
}
