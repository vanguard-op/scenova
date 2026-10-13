import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The Scenova mark.
///
/// `docs/Scenova/branding.md` → "Brand Mark & Logo System": three short
/// horizontal strokes in a row, the middle one peeling upward into a shallow
/// arc so the line breaks into movement. It reads in a single ink and is never
/// rotated, outlined, or set inside a play triangle.
///
/// The mark is drawn here rather than loaded from an asset because the asset
/// ledger does not yet list the mark's file paths; this is reported. It takes
/// its ink from the colour tokens, so it holds on light and dark surfaces and
/// reverses on dark.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 24, this.color, this.semanticLabel});

  final double size;

  /// Defaults to the reader's primary text colour, a single ink.
  final Color? color;

  /// Set when the mark stands alone and needs a screen-reader label.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? ScenovaColors.of(context).textPrimary;
    final mark = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BrandMarkPainter(color: ink),
        isComplex: false,
      ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: mark);
    return Semantics(label: semanticLabel, image: true, child: mark);
  }
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s * 0.13;

    final left = 0.22 * s;

    // Two shorter strokes hold the row, like lines of text of different
    // lengths.
    canvas.drawLine(Offset(left, 0.30 * s), Offset(0.62 * s, 0.30 * s), stroke);
    canvas.drawLine(Offset(left, 0.76 * s), Offset(0.74 * s, 0.76 * s), stroke);

    // The lead stroke leaves the row, peeling upward past the line above it.
    final peel = Path()
      ..moveTo(left, 0.53 * s)
      ..lineTo(0.44 * s, 0.53 * s)
      ..quadraticBezierTo(0.70 * s, 0.53 * s, 0.86 * s, 0.24 * s);
    canvas.drawPath(peel, stroke);
  }

  @override
  bool shouldRepaint(_BrandMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
