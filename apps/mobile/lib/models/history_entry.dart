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
