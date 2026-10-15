import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/theme/typography.dart';
import 'package:scenova_console/widgets/brand_lockup.dart';
import 'package:scenova_console/widgets/brand_mark.dart';

import 'support/harness.dart';

/// The console's wordmark type styles, as the theme resolves them.
ScenovaTextStyles styles() => ScenovaTextStyles.resolve();

/// The wordmark's alphabetic baseline, in global coordinates.
///
/// Read from the laid-out wordmark paragraph, so it is the baseline the row
/// itself aligned to.
double baselineOf(WidgetTester tester) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.text(BrandLockup.wordmark),
  );
  final fromTop = paragraph.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  return tester.getTopLeft(find.text(BrandLockup.wordmark)).dy + fromTop;
}

void main() {
  test('the display cap height is a fraction of the type size', () {
    // Lora's OS/2 sCapHeight is 700 against a 1000-unit em.
    expect(ScenovaTypography.displayCapHeightRatio, 0.70);
    expect(ScenovaTypography.capHeightOf(const TextStyle(fontSize: 20)), 14);
  });

  testWidgets('sizes the mark to the wordmark\'s cap height', (tester) async {
    final style = styles().h3;
    await pumpThemed(tester, BrandLockup(style: style));

    final mark = tester.getSize(find.byType(BrandMark));
    expect(mark.height, ScenovaTypography.capHeightOf(style));
    // The mark keeps its delivered aspect ratio; it is never squared off.
    expect(mark.width, closeTo(mark.height * BrandMark.aspectRatio, 0.5));
  });

  testWidgets('seats the mark on the wordmark\'s baseline', (tester) async {
    await pumpThemed(tester, BrandLockup(style: styles().h3));

    // The mark's ink bottom rests on the baseline, so its ink — the cap
    // height — spans exactly the cap band.
    expect(
      tester.getBottomLeft(find.byType(BrandMark)).dy,
      closeTo(baselineOf(tester), 0.5),
    );
  });

  testWidgets('sets the wordmark in the display family', (tester) async {
    await pumpThemed(tester, BrandLockup(style: styles().h3));

    final wordmark = tester.widget<Text>(find.text(BrandLockup.wordmark));
    expect(wordmark.style!.fontFamily, ScenovaTypography.displayFamily);
  });

  testWidgets('draws the mark from the delivered asset and names itself once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(tester, BrandLockup(style: styles().h3));

    final mark = find.byType(BrandMark);
    expect(mark, findsOneWidget);
    final svg = tester.widget<SvgPicture>(
      find.descendant(of: mark, matching: find.byType(SvgPicture)),
    );
    expect(svg.bytesLoader.toString(), contains(BrandMark.assetPath));
    // The mark is decorative, so the wordmark alone names the lockup rather
    // than the mark echoing it.
    expect(find.bySemanticsLabel(BrandLockup.wordmark), findsOneWidget);
    handle.dispose();
  });
}
