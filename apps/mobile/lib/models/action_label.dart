import 'package:flutter/foundation.dart';

/// One language the selection-action label can be shown in.
///
/// The label is the one string a reader sees inside another app's selection
/// menu, so the branding doc treats it as translatable content rather than a
/// fixed brand term and fixes English as the fallback.
@immutable
class ActionLabelLanguage {
  const ActionLabelLanguage({
    required this.locale,
    required this.name,
    required this.translated,
  });

  /// The language tag, as `C-020` carries it on the account (`locale`).
  final String locale;

  /// The language's name, as the reader reads it in the list.
  final String name;

  /// Whether the label has a translation in this language.
  ///
  /// Where it does not, the label falls back to English
  /// (`FEAT-012` → Edge Cases).
  final bool translated;

  @override
  bool operator ==(Object other) =>
      other is ActionLabelLanguage && other.locale == locale;

  @override
  int get hashCode => locale.hashCode;

  @override
  String toString() => 'ActionLabelLanguage($locale, translated: $translated)';
}

/// The languages the selection-action label can be shown in.
///
/// The branding doc externalizes the label for translation and fixes English as
/// the fallback, but does not enumerate the translated set. This catalogue is
/// the seam a translation lands in: a language whose translation has not shipped
/// still appears in the reader's choice, and the label falls back to English
/// until it does (`docs/Scenova/branding.md` → "Internationalization &
/// Localization"; `FEAT-012` → Edge Cases).
abstract final class ActionLabelLanguages {
  /// The fallback language, shown wherever a translation is missing.
  static const String fallback = 'en';

  static const ActionLabelLanguage english = ActionLabelLanguage(
    locale: 'en',
    name: 'English',
    translated: true,
  );

  static const ActionLabelLanguage portuguese = ActionLabelLanguage(
    locale: 'pt',
    name: 'Portuguese',
    translated: false,
  );

  static const ActionLabelLanguage french = ActionLabelLanguage(
    locale: 'fr',
    name: 'French',
    translated: false,
  );

  /// The offered languages, in the order they are listed.
  static const List<ActionLabelLanguage> all = <ActionLabelLanguage>[
    english,
    portuguese,
    french,
  ];

  /// The offered language for [locale].
  ///
  /// A locale the catalogue does not offer resolves to English, so a stored
  /// choice that no longer has an entry never leaves the label unnamed.
  static ActionLabelLanguage resolve(String locale) => all.firstWhere(
    (language) => language.locale == locale,
    orElse: () => english,
  );
}
