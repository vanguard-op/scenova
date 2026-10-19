import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the design system\'s bundle', () {
    // Read from the package root, which is where the test runner runs.
    final pubspec = File('pubspec.yaml').readAsStringSync();

    test('ships no icon files', () {
      // The product's icons are the platform pack both apps already bundle, so
      // nothing under the retired custom set's `assets/icons` is declared here
      // and no glyph is loaded from a file.
      expect(pubspec, isNot(contains('assets/icons')));
    });

    test('still ships the brand mark', () {
      // The mark is not an icon and is still the art the design system carries
      // (A-001, `BrandMark.assetPath`).
      expect(pubspec, contains('assets/brand/scenova-mark.svg'));
    });
  });
}
