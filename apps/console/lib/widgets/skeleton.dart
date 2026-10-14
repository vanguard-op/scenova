import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';

/// A placeholder used while a screen loads.
///
/// The queue renders a skeleton table while its first page is in flight
/// (`docs/Scenova/screens/09-review-queue.md` → Loading), so the layout holds
/// its shape and the page does not jump when the data lands.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 4});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < rows; i++) ...<Widget>[
          SkeletonLine(widthFactor: i.isEven ? 0.9 : 0.65),
          if (i != rows - 1) SizedBox(height: tokens.spacing.md),
        ],
      ],
    );
  }
}

/// A single placeholder bar. It holds still when reduce motion is on.
class SkeletonLine extends StatefulWidget {
  const SkeletonLine({super.key, this.height = 14, this.widthFactor = 1});

  final double height;
  final double widthFactor;

  @override
  State<SkeletonLine> createState() => _SkeletonLineState();
}

class _SkeletonLineState extends State<SkeletonLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ScenovaMotion.settle * 3,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widget.widthFactor,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final opacity = reduceMotion
              ? ScenovaOpacity.placeholderStill
              : ScenovaOpacity.placeholderMin +
                    (_controller.value *
                        (ScenovaOpacity.placeholderMax -
                            ScenovaOpacity.placeholderMin));
          return Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: colors.surfaceSecondary.withValues(alpha: opacity),
              borderRadius: BorderRadius.circular(ScenovaRadius.sm),
            ),
          );
        },
      ),
    );
  }
}
