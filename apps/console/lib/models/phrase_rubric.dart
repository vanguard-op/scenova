/// The phrase rubric the generation phrase is held to (`NFR-050`): seven words
/// or fewer, common words, one clear meaning.
///
/// The service owns the judgement and the regeneration; the console checks the
/// parts of the rubric that are mechanical before it sends an edit, so a phrase
/// that cannot pass is refused where the curator can see why and the entry's
/// stored phrase is left unchanged
/// (`docs/Scenova/screens/10-review-entry.md` → Edge Cases).
///
/// "Common words" and "one clear meaning" are a judgement the console cannot
/// make from the string alone, so they are left to the curator and the service;
/// only the length bounds are checked here.
library;

/// The most words a generation phrase may carry (`NFR-050`).
const int maxPhraseWords = 7;

/// The longest a generation phrase may be, matching the service's own bound
/// (`C-016` `phrase`, at most 60 characters).
const int maxPhraseLength = 60;

/// The reason [phrase] fails the rubric, or null when it passes.
///
/// The phrase is trimmed before it is judged, so trailing space never fails an
/// otherwise sound phrase.
String? phraseRubricError(String phrase) {
  final trimmed = phrase.trim();
  if (trimmed.isEmpty) {
    return 'Enter the phrase the clip is generated from.';
  }
  if (trimmed.length > maxPhraseLength) {
    return 'Keep the phrase to $maxPhraseLength characters or fewer.';
  }
  if (_wordCount(trimmed) > maxPhraseWords) {
    return 'Keep the phrase to $maxPhraseWords words or fewer.';
  }
  return null;
}

int _wordCount(String phrase) {
  return phrase.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
}
