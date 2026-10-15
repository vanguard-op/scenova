/// Layout dimensions the branding doc does not tokenise.
///
/// `docs/Scenova/branding.md` fixes the spacing, sizing, radius, shadow, and
/// type scales, and those are the values every screen consumes. It does not
/// declare the console's table weights or the measures its panels are held to,
/// because those belong to the console's own composition rather than to the
/// brand. They live here, in one place, so no screen carries a bare layout
/// number at a call site.
///
/// The console shell's chrome and the clip's own frame shape belong to the
/// shared components and travel with them in the design system.
abstract final class ConsoleLayout {
  /// The table's column weights. The word and the reason carry the most text;
  /// the sense, the age, and the state are short.
  static const int wordColumnFlex = 4;
  static const int senseColumnFlex = 2;
  static const int reasonColumnFlex = 4;
  static const int ageColumnFlex = 3;
  static const int stateColumnFlex = 3;

  /// The filter bar's word field width.
  static const double filterFieldWidth = 200;

  /// The width a centred empty or error state is held to, so a headline reads
  /// on one or two lines rather than stretching across the table's width.
  static const double stateMaxWidth = 480;

  /// The width of a detail screen's field labels.
  static const double detailLabelWidth = 120;

  // The Review Entry screen (`docs/Scenova/screens/10-review-entry.md`).

  /// The width at which the entry card and the evidence table sit side by side.
  /// Below it they stack, so the card is never squeezed into a column too
  /// narrow to read the phrase in.
  static const double entrySideBySideMinWidth = 760;

  /// The entry card's weight against the evidence table's. The clip and the
  /// phrase carry the visual focus; the evidence carries the decision, so the
  /// two stay close and the evidence keeps room for a report's note and time.
  static const int entryCardFlex = 5;
  static const int entryEvidenceFlex = 6;

  /// The evidence table's column weights. The report's note carries the most
  /// text; the reason and the time are short.
  static const int evidenceReasonFlex = 3;
  static const int evidenceNoteFlex = 6;
  static const int evidenceWhenFlex = 3;
  static const int feedbackRatingFlex = 6;
  static const int feedbackWhenFlex = 3;

  /// The phrase edit field's width, wide enough for a seven-word phrase.
  static const double phraseFieldWidth = 420;

  /// The width a confirmation modal is held to, so its wording reads on a few
  /// lines rather than stretching across the window.
  static const double dialogMaxWidth = 440;
}
