import 'package:flutter/foundation.dart';

import 'lookup.dart';

/// A lookup kept on the device.
///
/// Device history lives only on the device (`docs/Scenova/nfr.md` → "Data
/// lifecycle") and carries the word, its gloss phrase, the clip itself when it
/// was kept, and the poster frame derived from that clip.
@immutable
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.word,
    required this.phrase,
    required this.kind,
    required this.savedAt,
    this.clipUrl,
    this.clipLocalKey,
    this.posterLocalKey,
    this.hasAudio = false,
    this.lookupId,
  });

  final String id;
  final String word;
  final String phrase;
  final LookupKind kind;
  final DateTime savedAt;

  /// The clip's source URL, as the service served it.
  ///
  /// It is the source the device fetches the clip from, and the fallback a
  /// replay uses while online when no local copy could be kept.
  final String? clipUrl;

  /// The key of the saved clip in the device store; null when the device kept
  /// none (`FEAT-009`; `docs/Scenova/schema.md` → "DeviceHistoryEntry").
  ///
  /// The clip itself is kept with the entry, so it replays with no connection.
  /// When it is null the entry replays from [clipUrl] while online, and shows
  /// the still-frame stand-in when there is none.
  final String? clipLocalKey;

  /// The key of the poster frame derived from the saved clip, in the device
  /// store; null when no frame could be derived (`FEAT-009`).
  ///
  /// The frame is kept with the entry so the History row can show the lookup at
  /// a glance, and the row falls back to the shared still-frame stand-in when
  /// this is null.
  final String? posterLocalKey;

  final bool hasAudio;

  /// The service's id for the lookup this entry was saved from, when it had one.
  ///
  /// A lookup replayed from the device carries it back to the service, so the
  /// reader can still rate a clip they saw earlier — offline included
  /// (`FEAT-010`, Edge Cases; `C-012`). An entry with no service lookup (a
  /// seeded or pre-existing one) has none.
  final String? lookupId;

  /// Whether the entry has a clip to replay, on the device or from its source.
  bool get hasClip => clipLocalKey != null || clipUrl != null;

  /// The stored form of this entry.
  ///
  /// History is kept on the device and never leaves it, so the shape is the
  /// device's own; only what a row needs to render and replay is kept.
  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      id: json['id'] as String? ?? '',
      word: json['word'] as String? ?? '',
      phrase: json['phrase'] as String? ?? '',
      kind: LookupKind.fromWire(json['kind']) ?? LookupKind.word,
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      clipUrl: json['clipUrl'] as String?,
      clipLocalKey: json['clipLocalKey'] as String?,
      posterLocalKey: json['posterLocalKey'] as String?,
      hasAudio: json['hasAudio'] as bool? ?? false,
      lookupId: json['lookupId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'word': word,
    'phrase': phrase,
    'kind': kind.wire,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'clipUrl': clipUrl,
    'clipLocalKey': clipLocalKey,
    'posterLocalKey': posterLocalKey,
    'hasAudio': hasAudio,
    'lookupId': lookupId,
  };

  HistoryEntry copyWith({
    String? word,
    String? phrase,
    LookupKind? kind,
    DateTime? savedAt,
    String? clipUrl,
    String? clipLocalKey,
    String? posterLocalKey,
    bool? hasAudio,
    String? lookupId,
  }) {
    return HistoryEntry(
      id: id,
      word: word ?? this.word,
      phrase: phrase ?? this.phrase,
      kind: kind ?? this.kind,
      savedAt: savedAt ?? this.savedAt,
      clipUrl: clipUrl ?? this.clipUrl,
      clipLocalKey: clipLocalKey ?? this.clipLocalKey,
      posterLocalKey: posterLocalKey ?? this.posterLocalKey,
      hasAudio: hasAudio ?? this.hasAudio,
      lookupId: lookupId ?? this.lookupId,
    );
  }
}
