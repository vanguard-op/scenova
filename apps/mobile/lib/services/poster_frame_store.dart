import 'dart:convert';
import 'dart:typed_data';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The width of a kept poster frame, in pixels.
///
/// The frame is card-sized rather than the clip's own resolution: a stored clip
/// is a card-sized copy, and the poster it derives is card-sized as well
/// (`FEAT-009` → Edge Cases). 16:9 matches the clips.
const int kPosterFrameWidth = 320;

/// The height of a kept poster frame, in pixels.
const int kPosterFrameHeight = 180;

/// The quality the frame is encoded at. The frame is a card-sized still, not a
/// deliverable, so a moderate quality keeps the device store small.
const int kPosterFrameQuality = 70;

/// The poster frames the device keeps, one per saved lookup.
///
/// A poster is derived from an entry's clip and kept beside it on the device
/// (`FEAT-009`), so the History row shows the lookup at a glance without
/// opening the clip. Frames live only on the device, with the rest of history
/// (`docs/Scenova/nfr.md` → "Data lifecycle").
abstract interface class PosterFrameStore {
  /// Derives a card-sized frame from [clipUrl] and keeps it under [key].
  ///
  /// Resolves [key] when a frame was derived and kept, or null when none could
  /// be — a clip the platform cannot read, a source that is not a stream, or a
  /// derivation that fails. A null leaves the row on the shared still-frame
  /// stand-in (`FEAT-009` → Edge Cases).
  Future<String?> capture({required String clipUrl, required String key});

  /// The kept frame for [key], or null when the device holds none.
  Future<Uint8List?> frame(String key);

  /// Deletes the frame kept under [key].
  Future<void> remove(String key);

  /// Deletes every kept frame.
  Future<void> clear();

  /// Deletes every frame whose key is not in [keep].
  ///
  /// The device history keeps only the most recent lookups, so an entry that
  /// drops off must not leave its frame behind. Sweeping to the live keys keeps
  /// the frames bounded by the history that owns them.
  Future<void> pruneTo(Iterable<String> keep);
}

/// The device's poster frames, kept through `shared_preferences`.
///
/// A frame is derived from the clip with the platform's own decoder, which
/// reads a remote clip directly, and is kept encoded under its own key. A
/// derivation that fails resolves null rather than throwing: the reader's
/// lookup must not surface as an unhandled error, and the row has an honest
/// stand-in to fall back on.
class DevicePosterFrameStore implements PosterFrameStore {
  DevicePosterFrameStore({SharedPreferencesAsync? preferencesOverride})
    : _preferences = preferencesOverride;

  static const String _keyPrefix = 'history.poster.';

  SharedPreferencesAsync? _preferences;

  /// The platform store, created on first use, so a build that never derives a
  /// frame never reaches for the platform.
  SharedPreferencesAsync get _store =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<String?> capture({
    required String clipUrl,
    required String key,
  }) async {
    if (!_isStream(clipUrl)) return null;
    final Uint8List? bytes;
    try {
      bytes = await FcNativeVideoThumbnail().saveThumbnailToBytes(
        srcFile: clipUrl,
        srcFileUri: true,
        width: kPosterFrameWidth,
        height: kPosterFrameHeight,
        quality: kPosterFrameQuality,
      );
    } on Object {
      // The platform could not read the clip — no connection, an unsupported
      // source, or a decoder that declined. The entry keeps no frame.
      return null;
    }
    if (bytes == null || bytes.isEmpty) return null;
    await _store.setString('$_keyPrefix$key', base64Encode(bytes));
    return key;
  }

  @override
  Future<Uint8List?> frame(String key) async {
    final encoded = await _store.getString('$_keyPrefix$key');
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } on FormatException {
      // A frame the app cannot read is shown as none rather than crashing the
      // list; the next capture overwrites it.
      return null;
    }
  }

  @override
  Future<void> remove(String key) => _store.remove('$_keyPrefix$key');

  @override
  Future<void> clear() async {
    final keys = await _store.getKeys();
    for (final key in keys.where((key) => key.startsWith(_keyPrefix))) {
      await _store.remove(key);
    }
  }

  @override
  Future<void> pruneTo(Iterable<String> keep) async {
    final live = keep.toSet();
    final keys = await _store.getKeys();
    for (final key in keys) {
      if (!key.startsWith(_keyPrefix)) continue;
      if (live.contains(key.substring(_keyPrefix.length))) continue;
      await _store.remove(key);
    }
  }

  /// Whether [url] is a source the platform's decoder can read.
  ///
  /// The product's clips are served over http(s). A saved placeholder or a
  /// scripted source is not a stream, so it is never handed to the decoder.
  static bool _isStream(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}

/// Keeps poster frames only for the life of the process.
///
/// For tests and the preview gallery, and for the iOS extension, which runs in
/// its own process. A frame can be seeded so a test views a kept poster, and
/// [onCapture] scripts what a capture produces — a real decoder is a device
/// concern.
class InMemoryPosterFrameStore implements PosterFrameStore {
  InMemoryPosterFrameStore({
    Map<String, Uint8List> seed = const <String, Uint8List>{},
    this.onCapture,
  }) : _frames = Map<String, Uint8List>.of(seed);

  final Map<String, Uint8List> _frames;

  /// Scripts the frame a capture derives from a clip; null derives none, which
  /// is the row's stand-in path.
  final Future<Uint8List?> Function(String clipUrl)? onCapture;

  @override
  Future<String?> capture({
    required String clipUrl,
    required String key,
  }) async {
    final onCapture = this.onCapture;
    if (onCapture == null) return null;
    final bytes = await onCapture(clipUrl);
    if (bytes == null || bytes.isEmpty) return null;
    _frames[key] = bytes;
    return key;
  }

  @override
  Future<Uint8List?> frame(String key) async => _frames[key];

  @override
  Future<void> remove(String key) async => _frames.remove(key);

  @override
  Future<void> clear() async => _frames.clear();

  @override
  Future<void> pruneTo(Iterable<String> keep) async {
    final live = keep.toSet();
    _frames.removeWhere((key, _) => !live.contains(key));
  }
}
