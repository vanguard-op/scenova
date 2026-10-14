import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The clip card sits over the reading app, and Android reads
/// `windowIsTranslucent` from the theme in force when the window is laid out.
/// Flutter switches from the splash theme to the running theme before the first
/// frame draws, so both must declare it — in the day and night variants, and at
/// the API level that carries the splash-screen API and below it. A theme that
/// drops the item presents the card on an opaque window instead of over the
/// page, and only a device run would catch it (`FEAT-008`).
void main() {
  const List<String> styleFiles = <String>[
    'android/app/src/main/res/values/styles.xml',
    'android/app/src/main/res/values-night/styles.xml',
    'android/app/src/main/res/values-v31/styles.xml',
    'android/app/src/main/res/values-night-v31/styles.xml',
  ];

  for (final path in styleFiles) {
    test('$path keeps the clip card over the page', () {
      final source = File(path).readAsStringSync();
      for (final theme in <String>['LaunchTheme', 'NormalTheme']) {
        expect(
          _styleBlock(source, theme),
          contains('<item name="android:windowIsTranslucent">true</item>'),
          reason: '$theme lets the clip card run in a translucent window',
        );
      }
    });
  }
}

/// The body of the `<style name="theme">` block in [source].
String _styleBlock(String source, String theme) {
  final start = source.indexOf('<style name="$theme"');
  expect(start, isNonNegative, reason: '$theme is not declared');
  return source.substring(start, source.indexOf('</style>', start));
}
