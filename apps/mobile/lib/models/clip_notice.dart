import 'package:flutter/foundation.dart';

import 'lookup.dart';

/// A clip-ready notice as the notification service pushes it (`C-008`).
///
/// It names the lookup it is about and the clip's retrieval reference, and
/// nothing else: the reader's selection is never carried to the push provider.
/// A phrase clip reaches the device only this way — the lookup read path never
/// serves one (`FEAT-007`; `C-001`/`C-002`).
@immutable
class ClipNotice {
  const ClipNotice({
    required this.lookupId,
    required this.clipUrl,
    required this.durationSeconds,
    required this.resolution,
    required this.hasAudio,
  });

  /// The lookup whose generation finished.
  final String lookupId;

  /// Where the finished clip can be obtained.
  final String clipUrl;

  final double durationSeconds;
  final String resolution;
  final bool hasAudio;

  /// The clip the notice carries, for the player and for device history.
  Clip get clip => Clip(
    url: clipUrl,
    durationSeconds: durationSeconds,
    resolution: resolution,
    hasAudio: hasAudio,
  );

  /// Reads a notice out of a push data payload (`C-008`).
  ///
  /// The payload is `lookupId`, `clipUrl`, `durationSeconds`, `resolution`,
  /// and `hasAudio`; Firebase Cloud Messaging carries every value as a string.
  /// A payload without a lookup or a clip is not a notice and reads as null, so
  /// a malformed message never opens an empty surface or stores a clip that is
  /// not there.
  static ClipNotice? fromData(Map<String, dynamic> data) {
    final lookupId = _text(data['lookupId']);
    final clipUrl = _text(data['clipUrl']);
    if (lookupId == null || clipUrl == null) return null;
    return ClipNotice(
      lookupId: lookupId,
      clipUrl: clipUrl,
      durationSeconds: _seconds(data['durationSeconds']),
      resolution: _text(data['resolution']) ?? '360p',
      hasAudio: _flag(data['hasAudio']),
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The clip's duration. An unreadable value reads as none, and the player
  /// falls back to the product's clip cap rather than inventing a length.
  static double _seconds(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static bool _flag(Object? value) {
    if (value is bool) return value;
    if (value is String) return value.trim().toLowerCase() == 'true';
    return false;
  }

  @override
  bool operator ==(Object other) =>
      other is ClipNotice &&
      other.lookupId == lookupId &&
      other.clipUrl == clipUrl &&
      other.durationSeconds == durationSeconds &&
      other.resolution == resolution &&
      other.hasAudio == hasAudio;

  @override
  int get hashCode =>
      Object.hash(lookupId, clipUrl, durationSeconds, resolution, hasAudio);

  @override
  String toString() => 'ClipNotice($lookupId, $clipUrl)';
}
