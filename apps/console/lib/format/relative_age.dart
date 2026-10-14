import 'package:intl/intl.dart';

/// Formats how long ago an entry was queued, through the locale's own plural
/// rules rather than a hardcoded English string
/// (`docs/Scenova/branding.md` → "Internationalization & Localization →
/// Formats").
///
/// The queue's age column and the entry view share it, so an age reads the same
/// way wherever it appears.
String relativeAge(DateTime queuedAt, {DateTime? now, String? locale}) {
  final reference = (now ?? DateTime.now()).toUtc();
  final elapsed = reference.difference(queuedAt.toUtc());
  final localeName = locale ?? Intl.getCurrentLocale();

  if (elapsed.inMinutes < 1) return 'Just now';
  if (elapsed.inMinutes < 60) {
    return _ago(localeName, elapsed.inMinutes, 'minute', 'minutes');
  }
  if (elapsed.inHours < 24) {
    return _ago(localeName, elapsed.inHours, 'hour', 'hours');
  }
  if (elapsed.inDays < 7) {
    return _ago(localeName, elapsed.inDays, 'day', 'days');
  }
  if (elapsed.inDays < 30) {
    return _ago(localeName, elapsed.inDays ~/ 7, 'week', 'weeks');
  }
  if (elapsed.inDays < 365) {
    return _ago(localeName, elapsed.inDays ~/ 30, 'month', 'months');
  }
  return _ago(localeName, elapsed.inDays ~/ 365, 'year', 'years');
}

String _ago(String locale, int value, String singular, String plural) {
  return Intl.plural(
    value,
    one: '1 $singular ago',
    other: '$value $plural ago',
    locale: locale,
  );
}
