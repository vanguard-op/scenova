import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova_design/scenova_design.dart';

/// Puts the mark under the real theme, so its ink resolves the way it does in
/// the app.
Future<void> pumpMark(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(
        brightness: brightness,
        deviceClass: DeviceClass.mobile,
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  test('the delivered mark is bundled', () async {
    final data = await rootBundle.load(BrandMark.assetPath);
    expect(data.lengthInBytes, greaterThan(0));
  });

  test('the mark is far wider than it is tall, so it is never squared off', () {
    // The delivered mark's ink band is roughly 4.6:1; a square box would shrink
    // it to a sliver beside the wordmark.
    expect(BrandMark.aspectRatio, greaterThan(4));
  });

  testWidgets('renders the mark from the delivered asset', (tester) async {
    await pumpMark(tester, const BrandMark());
    await tester.pumpAndSettle();

    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.bytesLoader.toString(), contains(BrandMark.assetPath));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays the mark out at its delivered aspect ratio', (
    tester,
  ) async {
    await pumpMark(tester, const BrandMark(size: 24));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(BrandMark));
    expect(size.height, 24);
    expect(size.width, closeTo(24 * BrandMark.aspectRatio, 0.5));
    expect(size.width, greaterThan(size.height));
  });

  testWidgets('takes its ink from the primary text token', (tester) async {
    await pumpMark(tester, const BrandMark());
    await tester.pumpAndSettle();

    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      svg.colorFilter,
      ColorFilter.mode(ScenovaPalette.grey900Light, BlendMode.srcIn),
    );
  });

  testWidgets('reverses to the ink token on dark', (tester) async {
    await pumpMark(tester, const BrandMark(), brightness: Brightness.dark);
    await tester.pumpAndSettle();

    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      svg.colorFilter,
      ColorFilter.mode(ScenovaPalette.grey900Dark, BlendMode.srcIn),
    );
  });

  testWidgets('exposes a screen-reader label only when asked for', (
    tester,
  ) async {
    await pumpMark(tester, const BrandMark(semanticLabel: 'Scenova'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Scenova'), findsOneWidget);
  });
}
