import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/colors.dart';

/// The Scenova mark, drawn from the delivered asset
/// (`ASSETS.md` → A-001, `assets/brand/scenova-mark.svg`).
///
/// `docs/Scenova/branding.md` → "Brand Mark & Logo System": three short
/// horizontal strokes sit in a row, and the middle one peels upward into a
/// shallow arc so the line breaks into movement. It reads in a single ink and is
/// never rotated, outlined, or set inside a play triangle.
///
/// The delivered master frames the mark in a square canvas with the ink held in
/// a centred horizontal band (`ASSETS.md` → "centred at 76% of a square 1:1
/// canvas"). Drawing that whole square at an icon size would shrink the mark to
/// a sliver, so this widget frames the ink's band instead: [size] is the mark's
/// height and the width follows the delivered aspect ratio, which is roughly
/// 4.6:1. A caller gives the row that width rather than squaring the mark off.
///
/// The ink comes from the colour tokens, so the mark holds on light and dark
/// surfaces and reverses on dark.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 24, this.color, this.semanticLabel});

  /// The delivered mark: mark-only, transparent, in the ink token's light value.
  static const String assetPath = 'assets/brand/scenova-mark.svg';

  /// The mark's width over its height, taken from the delivered master's ink
  /// band (778 × 170 in its 1024 canvas). The mark is far wider than it is tall,
  /// so it is never drawn into a square.
  static const double aspectRatio = 778 / 170;

  /// The square canvas the master frames the ink band in, as a multiple of the
  /// mark's height, so the band can be framed out of it.
  static const double _canvasPerMarkHeight = 1024 / 170;

  /// The mark's height. The width follows [aspectRatio].
  final double size;

  /// Defaults to the reader's primary text colour, a single ink.
  final Color? color;

  /// Set when the mark stands alone and needs a screen-reader label.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? ScenovaColors.of(context).textPrimary;
    // The master is square; scaling it so the ink band spans the widget's width
    // and then clipping to the widget's box frames the band exactly. The band is
    // centred in its canvas, so centring the canvas on the box is enough.
    final canvas = size * _canvasPerMarkHeight;
    final mark = SizedBox(
      width: size * aspectRatio,
      height: size,
      child: ClipRect(
        child: OverflowBox(
          maxWidth: canvas,
          maxHeight: canvas,
          child: SvgPicture.asset(
            assetPath,
            width: canvas,
            height: canvas,
            fit: BoxFit.fill,
            // The master ships in the light ink; retinting it to the resolved
            // token keeps it on the brand in both themes.
            colorFilter: ColorFilter.mode(ink, BlendMode.srcIn),
          ),
        ),
      ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: mark);
    return Semantics(label: semanticLabel, image: true, child: mark);
  }
}
