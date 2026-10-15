import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'brand_mark.dart';

/// The horizontal brand lockup: the mark leading the wordmark
/// (`docs/Scenova/branding.md` → "Brand Mark & Logo System" and "Brand Mark
/// Direction"; the delivered form is `ASSETS.md` → A-004).
///
/// The wordmark is set in Lora. The mark is sized to the wordmark's cap height
/// and seated on the wordmark's baseline, so its ink occupies exactly the cap
/// band the type defines. The relationship holds at any type size, so the
/// lockup reads the same on the console's shell and its sign-in screen.
///
/// The mark is decorative here — the wordmark names the product — so it is
/// excluded from semantics and the lockup announces itself once.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, required this.style, this.color, this.gap});

  /// The wordmark, set in the display family.
  static const String wordmark = 'Scenova';

  /// The wordmark's type style. It must be a display-family (Lora) style,
  /// because the cap height the mark is sized to comes from that family's
  /// metrics.
  final TextStyle style;

  /// Defaults to the primary text colour, so the wordmark takes the ink token
  /// and holds on light and dark surfaces.
  final Color? color;

  /// The space between the mark and the wordmark. Defaults to `space-sm`.
  final double? gap;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final capHeight = ScenovaTypography.capHeightOf(style);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        // The mark's ink bottom rests on the wordmark's baseline, so its ink
        // height — the cap height — spans exactly the cap band.
        _CapBand(
          capHeight: capHeight,
          child: Padding(
            padding: EdgeInsets.only(right: gap ?? tokens.spacing.sm),
            child: BrandMark(size: capHeight),
          ),
        ),
        Flexible(
          child: Text(
            wordmark,
            style: style.copyWith(color: color ?? colors.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Reports an alphabetic baseline [capHeight] below its top.
///
/// The row it sits in is baseline-aligned, so seating the mark's ink bottom on
/// that reported baseline puts the mark exactly on the wordmark's cap band.
class _CapBand extends SingleChildRenderObjectWidget {
  const _CapBand({required Widget super.child, required this.capHeight});

  final double capHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCapBand(capHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderCapBand renderObject) {
    renderObject.capHeight = capHeight;
  }
}

class _RenderCapBand extends RenderProxyBox {
  _RenderCapBand(this.capHeight);

  double capHeight;

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) => capHeight;
}
