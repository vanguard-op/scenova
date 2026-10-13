import '../models/lookup.dart';

/// The phrase limit.
///
/// The contract refuses a selection over six words (`C-001`, 400); the product
/// treats one word as a word lookup and two to six words as a short phrase.
const int kMaxSelectionWords = 6;

/// A selection as it arrives from the platform entry point, normalised for a
/// lookup.
///
/// This is where the entry gate's rules live, so both the Android selection
/// action and the iOS share extension resolve the same way:
/// - an empty or whitespace-only selection opens an empty state and starts no
///   lookup;
/// - a selection over the six-word limit is kept within it, with a notice;
/// - punctuation around the selection is trimmed before the lookup.
///
/// It also decides the lookup kind: one word is a word, two to six words are a
/// short phrase.
class CaptureSelection {
  const CaptureSelection({
    required this.text,
    required this.kind,
    required this.isEmpty,
    required this.overLimit,
    required this.truncatedFrom,
    this.notice,
  });

  /// The normalised text, trimmed of surrounding whitespace and punctuation and
  /// kept within the six-word limit. Empty when [isEmpty] is true.
  final String text;

  /// Null when [isEmpty] is true.
  final LookupKind? kind;

  final bool isEmpty;
  final bool overLimit;

  /// The word count of the selection as received, before truncation.
  final int truncatedFrom;

  /// A reader-facing note when the selection needed a correction.
  final String? notice;

  /// A selection that starts no lookup.
  static const CaptureSelection empty = CaptureSelection(
    text: '',
    kind: null,
    isEmpty: true,
    overLimit: false,
    truncatedFrom: 0,
  );

  static const String overLimitNotice =
      'Scenova looks up single words and short phrases — up to six words.';

  int get wordCount => isEmpty ? 0 : text.split(' ').length;

  /// Parses a raw selection from a platform entry point.
  static CaptureSelection parse(String? raw) {
    final normalised = _normaliseWhitespace(raw ?? '');
    if (normalised.isEmpty) return empty;

    final trimmed = _trimPunctuation(normalised);
    if (trimmed.isEmpty) return empty;

    final words = trimmed.split(' ');
    if (words.length > kMaxSelectionWords) {
      final kept = words.take(kMaxSelectionWords).join(' ');
      return CaptureSelection(
        text: kept,
        kind: LookupKind.phrase,
        isEmpty: false,
        overLimit: true,
        truncatedFrom: words.length,
        notice: overLimitNotice,
      );
    }

    return CaptureSelection(
      text: trimmed,
      kind: words.length == 1 ? LookupKind.word : LookupKind.phrase,
      isEmpty: false,
      overLimit: false,
      truncatedFrom: words.length,
    );
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
