import '../models/lookup.dart';

/// The phrase limit.
///
/// The contract refuses a selection over six words (`C-001`, 400); the product
/// treats one word as a word lookup and two to six words as a short phrase.
const int kMaxSelectionWords = 6;

/// The character bound on a selection.
///
/// The contract refuses a selection over eighty characters as well as over the
/// word limit (`C-001`, 400). It catches the selection that sits within the word
/// limit but is still too long to send — a run of long words, say.
const int kMaxSelectionCharacters = 80;

/// Which bound held a selection back from a lookup.
enum SelectionLimit {
  /// Within the word and character bounds.
  none,

  /// Over the six-word phrase limit.
  words,

  /// Within the word limit but over the character bound.
  characters,
}

/// A selection as it arrives from the platform entry point, normalised for a
/// lookup.
///
/// This is where the entry gate's rules live, so both the Android selection
/// action and the iOS share extension resolve the same way:
/// - an empty or whitespace-only selection opens an empty state and starts no
///   lookup;
/// - a selection over the six-word limit, or over the character bound, is kept
///   within it, with a notice;
/// - punctuation around the selection is trimmed before the lookup.
///
/// It also decides the lookup kind: one word is a word, two to six words are a
/// short phrase.
class CaptureSelection {
  const CaptureSelection({
    required this.text,
    required this.kind,
    required this.isEmpty,
    required this.limit,
    required this.truncatedFrom,
  });

  /// The normalised text, trimmed of surrounding whitespace and punctuation and
  /// kept within the word and character bounds. Empty when [isEmpty] is true.
  final String text;

  /// Null when [isEmpty] is true.
  final LookupKind? kind;

  final bool isEmpty;

  /// Which bound the selection was held within, or [SelectionLimit.none].
  final SelectionLimit limit;

  /// The word count of the selection as received, before truncation.
  final int truncatedFrom;

  /// A selection that starts no lookup.
  static const CaptureSelection empty = CaptureSelection(
    text: '',
    kind: null,
    isEmpty: true,
    limit: SelectionLimit.none,
    truncatedFrom: 0,
  );

  static const String overLimitNotice =
      'Scenova looks up single words and short phrases — up to six words.';

  /// The notice for a selection within the word limit but over the character
  /// bound. It says what Scenova handles rather than naming the bound, which the
  /// reader has no way to count.
  static const String tooLongNotice =
      'Scenova looks up single words and short phrases.';

  /// Whether the selection was held back from a lookup for its length.
  bool get overLimit => limit != SelectionLimit.none;

  /// A reader-facing note when the selection needed a correction, or null.
  String? get notice => switch (limit) {
    SelectionLimit.none => null,
    SelectionLimit.words => overLimitNotice,
    SelectionLimit.characters => tooLongNotice,
  };

  int get wordCount => isEmpty ? 0 : text.split(' ').length;

  /// Parses a raw selection from a platform entry point.
  static CaptureSelection parse(String? raw) {
    final normalised = _normaliseWhitespace(raw ?? '');
    if (normalised.isEmpty) return empty;

    final trimmed = _trimPunctuation(normalised);
    if (trimmed.isEmpty) return empty;

    final words = trimmed.split(' ');
    final overWords = words.length > kMaxSelectionWords;
    final kept = overWords
        ? words.take(kMaxSelectionWords).toList(growable: false)
        : words;

    return CaptureSelection(
      text: _withinCharacterBound(kept),
      kind: words.length == 1 ? LookupKind.word : LookupKind.phrase,
      isEmpty: false,
      // The word limit is the guidance the reader is given, so it is named
      // first; the character bound is a second guard on the same selection.
      limit: overWords
          ? SelectionLimit.words
          : trimmed.length > kMaxSelectionCharacters
          ? SelectionLimit.characters
          : SelectionLimit.none,
      truncatedFrom: words.length,
    );
  }

  /// The words joined and kept within the character bound.
  ///
  /// A trailing word is dropped rather than cut mid-word, so the kept selection
  /// still reads as words; a lone word longer than the bound is the one case
  /// where the cut falls inside it, since there is nothing shorter to keep. A
  /// lookup therefore never carries more than the contract allows (`C-001`).
  static String _withinCharacterBound(List<String> words) {
    var kept = words;
    var text = kept.join(' ');
    while (kept.length > 1 && text.length > kMaxSelectionCharacters) {
      kept = kept.sublist(0, kept.length - 1);
      text = kept.join(' ');
    }
    return text.length > kMaxSelectionCharacters
        ? text.substring(0, kMaxSelectionCharacters)
        : text;
  }

  static String _normaliseWhitespace(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _trimPunctuation(String value) {
    const punctuation = '.,;:!?…"\'“”‘’()[]{}<>«»—–/\\|`~^*_+=#@&%\$';
    var start = 0;
    var end = value.length;
    while (start < end && punctuation.contains(value[start])) {
      start++;
    }
    while (end > start && punctuation.contains(value[end - 1])) {
      end--;
    }
    return value.substring(start, end).trim();
  }
}
