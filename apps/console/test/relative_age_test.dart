import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/format/relative_age.dart';

void main() {
  final now = DateTime.utc(2026, 10, 14, 12);

  String age(Duration elapsed) =>
      relativeAge(now.subtract(elapsed), now: now, locale: 'en');

  group('relativeAge', () {
    test('reads the freshest entries as just now', () {
      expect(age(const Duration(seconds: 30)), 'Just now');
    });

    test('reads minutes, hours, and days', () {
      expect(age(const Duration(minutes: 1)), '1 minute ago');
      expect(age(const Duration(minutes: 45)), '45 minutes ago');
      expect(age(const Duration(hours: 1)), '1 hour ago');
      expect(age(const Duration(hours: 3)), '3 hours ago');
      expect(age(const Duration(days: 1)), '1 day ago');
      expect(age(const Duration(days: 2)), '2 days ago');
    });

    test('rolls up to weeks, months, and years', () {
      expect(age(const Duration(days: 10)), '1 week ago');
      expect(age(const Duration(days: 20)), '2 weeks ago');
      expect(age(const Duration(days: 60)), '2 months ago');
      expect(age(const Duration(days: 400)), '1 year ago');
    });

    test('selects the plural form through the locale', () {
      // The form comes from the locale's own plural rules, so a locale with a
      // different rule set than English's still reads correctly.
      expect(
        relativeAge(
          now.subtract(const Duration(days: 1)),
          now: now,
          locale: 'en',
        ),
        '1 day ago',
      );
      expect(
        relativeAge(
          now.subtract(const Duration(days: 2)),
          now: now,
          locale: 'en',
        ),
        '2 days ago',
      );
    });
  });
}
