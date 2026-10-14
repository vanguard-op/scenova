/// Layout dimensions the branding doc does not tokenise.
///
/// `docs/Scenova/branding.md` fixes the spacing, sizing, radius, shadow, and
/// type scales, and those are the values every screen consumes. It does not
/// declare the console's chrome widths — the sidebar, the top bar, the table's
/// column weights — because those belong to the console's own composition
/// rather than to the brand. They live here, in one place, so no screen carries
/// a bare layout number at a call site.
abstract final class ConsoleLayout {
  /// The sidebar's width. Wide enough for the queue label and its count, and
  /// narrow enough to leave the table room.
  static const double sidebarWidth = 248;

  /// The sticky top bar's height, holding the mark and the operator's identity.
  static const double topBarHeight = 64;

  /// The body's maximum width, so the table does not stretch to an unreadable
  /// width on a very wide display.
  static const double contentMaxWidth = 1440;

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
}
