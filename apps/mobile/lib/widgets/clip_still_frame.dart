import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import 'brand_mark.dart';

/// The still frame the shared Clip Player draws when it has no clip frame to
/// show: the brand mark centred on the primary tint.
///
/// It is also the stand-in a History thumbnail shows when its entry has no clip,
/// or a poster frame that could not be derived from the clip (`FEAT-009` →
/// Edge Cases; `docs/Scenova/screens/06-history.md` → Edge Cases). One widget
/// carries it, so the two surfaces read as the same frame.
///
/// [markSize] and [padding] default to the Clip Player's own poster; a smaller
/// card passes its own so the mark stays inside it.
class ClipStillFrame extends StatelessWidget {
  const ClipStillFrame({super.key, this.markSize, this.padding});

  /// The mark's height. Defaults to the feature-icon size.
  final double? markSize;

  /// The inset around the mark. Defaults to the card padding.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Container(
      padding: padding ?? EdgeInsets.all(tokens.spacing.md),
      decoration: BoxDecoration(
        color: colors.primaryTint,
        borderRadius: BorderRadius.circular(ScenovaRadius.md),
      ),
      child: BrandMark(size: markSize ?? tokens.sizing.iconLg),
    );
  }
}
