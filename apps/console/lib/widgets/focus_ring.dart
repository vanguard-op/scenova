import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Draws the brand's focus ring: a 2px `primary-500` outline with a 2px
/// offset (`docs/Scenova/branding.md` → "Accessibility → Focus indicators").
///
/// It is drawn outside the control's bounds so focusing never shifts the
/// layout, and it is the same ring on every interactive element, so the console
/// is fully keyboard-navigable with one visible focus treatment.
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.visible,
    required this.radius,
    required this.child,
  });

  final bool visible;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: visible
          ? _FocusRingPainter(
              color: ScenovaColors.of(context).focusRing,
              radius: radius,
            )
          : null,
      child: child,
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  /// The offset between the control and its ring, and the ring's width.
  static const double offset = 2;
  static const double width = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).inflate(offset);
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(radius + offset),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  @override
  bool shouldRepaint(_FocusRingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
