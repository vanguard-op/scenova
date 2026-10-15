import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// The device's own store for the clips its history keeps.
///
/// A saved lookup keeps the clip itself, not only a reference to it, so it
/// replays with no connection (`FEAT-009`; `docs/Scenova/user-flow.md` → Flow 3,
/// Alternate Path A). The clip is kept on the device only, beside the entry and
/// its poster frame, and is removed when the reader clears history or deletes
/// the app (`docs/Scenova/nfr.md` → "Data lifecycle").
///
/// Every reader's device keeps the clip while the tiers are pre-account: the
/// Free and Pro split that withholds clip retention from Free arrives with the
/// account feature, and nothing here reads a plan.
abstract interface class ClipStore {
  /// Keeps the clip at [clipUrl] on the device under [key].
  ///
  /// Resolves [key] when the clip was fetched and kept, or null when it could
  /// not be — a source the device cannot reach, an empty response, or a write
  /// the device refused. A null leaves the entry with its source alone, which
  /// still replays while online.
  Future<String?> save({required String clipUrl, required String key});

  /// The device-local source for [key], or null when the device holds none.
  ///
  /// The source is a `file:` URL the shared Clip Player opens without a
  /// connection.
  Future<String?> source(String key);

  /// Deletes the clip kept under [key].
  Future<void> remove(String key);

  /// Deletes every kept clip.
  Future<void> clear();

  /// Deletes every clip whose key is not in [keep].
  ///
  /// The device history keeps only the most recent lookups, so an entry that
  /// drops off must not leave its clip behind. Sweeping to the live keys keeps
  /// the clips bounded by the history that owns them.
  Future<void> pruneTo(Iterable<String> keep);
}

/// The device's clips, kept as files under the app's own support directory.
///
/// A clip is a few hundred kilobytes of video, so it is kept as a file rather
/// than in the preferences document that carries the entries. Each key names
/// one file; a key the filesystem cannot carry is percent-encoded, so the file
/// name is always a legal one.
class DeviceClipStore implements ClipStore {
  DeviceClipStore({http.Client? client, Directory? directoryOverride})
    : _client = client ?? http.Client(),
      _directory = directoryOverride;

  /// The directory under the app's support directory that holds the clips.
  static const String directoryName = 'clips';

  /// The prefix every kept clip's file name carries.
  static const String _prefix = 'clip_';

  final http.Client _client;
  Directory? _directory;

  /// The directory the clips are kept in, created on first use.
  Future<Directory> _dir() async {
    final existing = _directory;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$directoryName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _directory = dir;
  }

  Future<File> _file(String key) async =>
      File('${(await _dir()).path}/$_prefix${Uri.encodeComponent(key)}');

  @override
  Future<String?> save({required String clipUrl, required String key}) async {
    final uri = Uri.tryParse(clipUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      // A scripted or placeholder source is not a clip the device can fetch.
      return null;
    }
    final List<int> bytes;
    try {
      final response = await _client.get(uri).timeout(AppConfig.requestTimeout);
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      bytes = response.bodyBytes;
    } on Object {
      // The clip could not be fetched — no connection, or a source that
      // declined. The entry keeps its source and no local copy.
      return null;
    }
    try {
      final file = await _file(key);
      await file.writeAsBytes(bytes, flush: true);
      return key;
    } on Object {
      // The device refused the write; the reader's lookup must not surface as
      // an unhandled error, and the entry keeps no local copy.
      return null;
    }
  }

  @override
  Future<String?> source(String key) async {
    try {
      final file = await _file(key);
      if (!await file.exists()) return null;
      return Uri.file(file.path).toString();
    } on Object {
      // A store the device cannot read holds nothing; the row falls back to the
      // entry's source, or to the still-frame stand-in.
      return null;
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      final file = await _file(key);
      if (await file.exists()) await file.delete();
    } on Object {
      // The clip is swept when history is next loaded.
    }
  }

  @override
  Future<void> clear() async {
    await _deleteWhere((_) => true);
  }

  @override
  Future<void> pruneTo(Iterable<String> keep) async {
    final live = keep
        .map((key) => '$_prefix${Uri.encodeComponent(key)}')
        .toSet();
    await _deleteWhere((name) => !live.contains(name));
  }

  /// Deletes every kept clip whose file name satisfies [drop].
  Future<void> _deleteWhere(bool Function(String name) drop) async {
    try {
      final dir = await _dir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(_prefix)) continue;
        if (!drop(name)) continue;
        try {
          await entity.delete();
        } on Object {
          // The clip stays until the next sweep.
        }
      }
    } on Object {
      // A sweep that fails costs the reader nothing.
    }
  }
}

/// Keeps clips only for the life of the process.
///
/// For tests and the preview gallery, and for the iOS extension, which runs in
/// its own process. A clip can be seeded so a test views a kept clip, and
/// [onSave] scripts what a save produces — a real fetch is a device concern.
class InMemoryClipStore implements ClipStore {
  InMemoryClipStore({
    Map<String, String> seed = const <String, String>{},
    this.onSave,
  }) : _sources = Map<String, String>.of(seed);

  final Map<String, String> _sources;

  /// Scripts the local source a save produces; null keeps none, which is the
  /// entry's source-only path.
  final Future<String?> Function(String clipUrl)? onSave;

  @override
  Future<String?> save({required String clipUrl, required String key}) async {
    final onSave = this.onSave;
    if (onSave == null) return null;
    final source = await onSave(clipUrl);
    if (source == null || source.isEmpty) return null;
    _sources[key] = source;
    return key;
  }

  @override
  Future<String?> source(String key) async => _sources[key];

  @override
  Future<void> remove(String key) async => _sources.remove(key);

  @override
  Future<void> clear() async => _sources.clear();

  @override
  Future<void> pruneTo(Iterable<String> keep) async {
    final live = keep.toSet();
    _sources.removeWhere((key, _) => !live.contains(key));
  }
}
