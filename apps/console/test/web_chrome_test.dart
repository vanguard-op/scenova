import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The console is a Flutter Web app: its tab icon and its install icon are
/// named by bundle paths in `web/index.html` and `web/manifest.json`, and the
/// build carries only the assets the pubspec declares. A path that drifts from
/// the declaration ships a 404 for the brand's mark — a failure no widget test
/// sees — so both entry points are held to the delivered asset (A-006) and to
/// the pubspec that puts it in the bundle.
void main() {
  /// The pubspec key a bundled web path resolves to.
  ///
  /// Flutter serves an app's own assets under `assets/`, so the rest of a web
  /// path is the key as the pubspec writes it, resolved from this package's
  /// `assets/` directory.
  String assetKeyOf(String path) {
    expect(path, startsWith('assets/'), reason: path);
    return path.substring('assets/'.length);
  }

  test('the favicon names a delivered, bundled asset', () {
    final index = File('web/index.html').readAsStringSync();
    final link = RegExp(r'<link[^>]*rel="icon"[^>]*>').firstMatch(index);
    expect(link, isNotNull, reason: 'web/index.html declares a favicon');

    final href = RegExp(r'href="([^"]+)"')
        .firstMatch(link!.group(0)!)!
        .group(1)!;
    final key = assetKeyOf(href);
    expect(File(key).existsSync(), isTrue, reason: 'delivered: $key');
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains(key),
      reason: 'bundled by pubspec: $key',
    );
  });

  test('the install icons name a delivered, bundled asset', () {
    final manifest = jsonDecode(
      File('web/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final icons = manifest['icons'] as List<dynamic>?;
    expect(icons, isNotNull, reason: 'web/manifest.json declares its icons');
    expect(icons, isNotEmpty);

    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final icon in icons!) {
      final key = assetKeyOf((icon as Map<String, dynamic>)['src'] as String);
      expect(File(key).existsSync(), isTrue, reason: 'delivered: $key');
      expect(pubspec, contains(key), reason: 'bundled by pubspec: $key');
    }
  });
}
