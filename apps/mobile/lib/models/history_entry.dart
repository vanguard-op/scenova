import 'package:flutter/foundation.dart';

import 'lookup.dart';

/// A lookup kept on the device.
///
/// Device history lives only on the device (`docs/Scenova/nfr.md` → "Data
/// lifecycle") and carries the word, its gloss phrase, and the clip when one
/// was saved.
@immutable
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.word,
    required this.phrase,
    required this.kind,
    required this.savedAt,
    this.clipUrl,
    this.hasAudio = false,
  });

  final String id;
  final String word;
  final String phrase;
  final LookupKind kind;
  final DateTime savedAt;
  final String? clipUrl;
  final bool hasAudio;

  bool get hasClip => clipUrl != null;

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
      hasAudio: json['hasAudio'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'word': word,
    'phrase': phrase,
    'kind': kind.wire,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'clipUrl': clipUrl,
    'hasAudio': hasAudio,
  };

  HistoryEntry copyWith({
    String? word,
    String? phrase,
    LookupKind? kind,
    DateTime? savedAt,
    String? clipUrl,
    bool? hasAudio,
  }) {
    return HistoryEntry(
      id: id,
      word: word ?? this.word,
      phrase: phrase ?? this.phrase,
      kind: kind ?? this.kind,
      savedAt: savedAt ?? this.savedAt,
      clipUrl: clipUrl ?? this.clipUrl,
      hasAudio: hasAudio ?? this.hasAudio,
    );
  }
}
