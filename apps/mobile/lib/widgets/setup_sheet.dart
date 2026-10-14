import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';

/// The setup panel: a solid, draggable bottom sheet carrying the setup content
/// over the walkthrough clip (`docs/Scenova/screens/01-onboarding.md` → Layout,
/// Components, and States).
///
/// It rests at the height of its content, so the clip's upper band stays visible
/// above it. Dragging it down reduces it to its handle at the foot of the screen
/// and reveals the clip in full; dragging it up returns the setup content to
/// full height. The content scrolls inside the sheet when it is taller than the
/// room the sheet has.
///
/// The panel carries content over moving imagery, so it is opaque at every
/// position it can rest at: its composite colour never changes with the frame
/// behind it, so its text keeps a fixed contrast ratio against the clip
/// (`docs/Scenova/branding.md` → "Shadows" and "Accessibility"). A translucent
/// or blurred surface is never used over the clip, and the sheet is never faded.
///
/// Under reduce motion the panel still moves under the reader's own drag and
/// settles without a bounce; it simply lands without an animated transition.
/// Only the clip behind it is held on a still frame.
///
/// The sheet positions itself against the bottom edge, so place it as a child of
/// a [Stack].
class SetupSheet extends StatefulWidget {
  const SetupSheet({
    super.key,
    required this.child,
    required this.availableHeight,
    this.reduceMotion = false,
  });

  /// The setup content the sheet carries.
  final Widget child;

  /// The height of the surface the sheet is anchored in. The sheet leaves a band
  /// of the clip visible above it even when the content is taller than the room.
  final double availableHeight;

  /// When on, the sheet still follows the reader's drag and settles without a
  /// bounce, but it lands without an animated transition.
  final bool reduceMotion;

  @override
  State<SetupSheet> createState() => SetupSheetState();
}

/// The setup sheet's state.
///
/// Public so a test can read the sheet's resting position, including the
/// "Clip revealed" state (`docs/Scenova/screens/01-onboarding.md` → States).
class SetupSheetState extends State<SetupSheet>
    with SingleTickerProviderStateMixin {
  /// The tolerance within which a position counts as the handle rest, so a
  /// floating-point settle lands on the state it visually is.
  static const double _restTolerance = 0.5;

  /// The sheet's own surface, so its laid-out height gives the distance between
  /// the two positions it can rest at.
  final GlobalKey _surfaceKey = GlobalKey();

  final ScrollController _scroll = ScrollController();

  /// Drives the settle once the reader lets go of a drag.
  late final AnimationController _settle;
  Animation<double>? _settleAnimation;

  /// The height the sheet rests at, measured while it is at rest.
  ///
  /// The sheet shrinks as the reader drags it down, so its own height stops
  /// telling the drag how far it can travel; this is the height it travels from.
  double _restHeight = 0;

  /// How far the sheet is moved down from its resting position, in pixels.
  double _offset = 0;

  /// Whether the sheet is resting at its handle with the clip revealed.
  bool _revealed = false;

  /// Whether a rest-position sync is already queued for the end of this frame.
  bool _restSyncScheduled = false;

  /// Whether the sheet rests at its handle with the walkthrough clip revealed.
  bool get clipRevealed => _revealed;

  /// The padding under the content: the bottom inset the content must clear,
  /// plus the panel's own padding.
  double get _bottomPad =>
      MediaQuery.viewPaddingOf(context).bottom +
      ScenovaTokens.of(context).spacing.lg;

  /// The height of the handle strip at the head of the sheet.
  double get _handleExtent => ScenovaTokens.of(context).sizing.buttonHeight;

  /// The distance between the two positions the sheet can rest at.
  ///
  /// The handle and the padding under the content stay on screen when the clip
  /// is revealed, so the content's height is the whole of the travel.
  double get _maxOffset {
    final max = _restHeight - _handleExtent - _bottomPad;
    return max > 0 ? max : 0;
  }

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: ScenovaMotion.settle)
      ..addListener(_onSettleTick)
      ..addStatusListener(_onSettleStatus);
  }

  @override
  void dispose() {
    _settle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSettleTick() {
    final animation = _settleAnimation;
    if (animation == null) return;
    setState(() => _offset = animation.value);
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _recordRestPosition();
  }

  /// The rest position the sheet settles at, given where the drag left it and
  /// how fast the reader let go.
  ///
  /// A flick carries the drag on for one settle, so its projected travel decides
  /// the direction rather than a bare speed threshold.
  double _settleTarget(double velocity) {
    final max = _maxOffset;
    if (max == 0) return 0;
    final seconds =
        ScenovaMotion.settle.inMicroseconds / Duration.microsecondsPerSecond;
    final projected = _offset + velocity * seconds;
    return projected > max / 2 ? max : 0;
  }

  /// Moves the sheet to [target], settling without a bounce.
  void _settleTo(double target) {
    final clamped = target.clamp(0.0, _maxOffset);
    if (widget.reduceMotion) {
      // The panel is already under the reader's finger; under reduce motion it
      // lands where it was let go rather than transitioning there.
      _settle.stop();
      setState(() => _offset = clamped);
      _recordRestPosition();
      return;
    }
    _settleAnimation = _settle.drive(
      Tween<double>(
        begin: _offset,
        end: clamped,
      ).chain(CurveTween(curve: ScenovaMotion.enter)),
    );
    _settle.forward(from: 0);
  }

  void _recordRestPosition() {
    final revealed = _revealedAt(_offset);
    if (revealed != _revealed) setState(() => _revealed = revealed);
  }

  bool _revealedAt(double offset) {
    final max = _maxOffset;
    return max > 0 && offset >= max - _restTolerance;
  }

  void _onDragStart(DragStartDetails details) {
    _settle.stop();
    setState(() => _revealed = false);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final max = _maxOffset;
    setState(() => _offset = (_offset + details.delta.dy).clamp(0.0, max));
  }

  void _onDragEnd(DragEndDetails details) {
    _settleTo(_settleTarget(details.primaryVelocity ?? 0));
  }

  /// The handle's accessible action: move the sheet to its other rest position,
  /// for a reader who cannot drag it.
  void _toggle() => _settleTo(clipRevealed ? 0 : _maxOffset);

  /// Reads the sheet's resting height, and keeps the sheet at its handle when
  /// the content changes height while the clip is revealed.
  ///
  /// Runs after layout, because both facts come from the laid-out sheet.
  void _scheduleRestSync() {
    if (_restSyncScheduled) return;
    _restSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restSyncScheduled = false;
      if (!mounted) return;
      final box = _surfaceKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      if (_offset == 0) {
        if (box.size.height != _restHeight) {
          setState(() => _restHeight = box.size.height);
        }
        return;
      }
      if (_revealed) {
        final max = _maxOffset;
        if (_offset != max) setState(() => _offset = max);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final padding = MediaQuery.paddingOf(context);
    final bottomPad = _bottomPad;

    if (_offset == 0 || _revealed) _scheduleRestSync();

    // The sheet never covers the clip completely: a band stays visible above it
    // even when the content is taller than the room the sheet has.
    final maxSheetHeight = math.max(
      0.0,
      widget.availableHeight - tokens.spacing.xxxl,
    );

    // At rest the sheet sizes to its content. Once the reader drags it, its
    // height shrinks with the drag, so the content leaves the foot of the screen
    // and the handle comes to rest above the bottom inset with the clip behind
    // the panel below it.
    final collapsedHeight = _handleExtent + bottomPad;
    final height = _offset > 0
        ? math.max(collapsedHeight, _restHeight - _offset)
        : null;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SizedBox(
        height: height,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: ConstrainedBox(
            key: _surfaceKey,
            constraints: BoxConstraints(maxHeight: maxSheetHeight),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(ScenovaRadius.lg),
                ),
                boxShadow: tokens.shadowXl,
              ),
              // The panel paints its own surface, so the content's controls need
              // a Material of their own to carry their ink over it.
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _handle(context, tokens),
                    Flexible(
                      child: SingleChildScrollView(
                        controller: _scroll,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            math.max(tokens.spacing.lg, padding.left),
                            0,
                            math.max(tokens.spacing.lg, padding.right),
                            0,
                          ),
                          child: widget.child,
                        ),
                      ),
                    ),
                    // Sits outside the scrolling content, so the foot of the
                    // panel is solid surface even once the content has left it.
                    SizedBox(height: bottomPad),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The drag handle at the head of the sheet, and the sheet's accessible
  /// alternative to dragging.
  Widget _handle(BuildContext context, ScenovaTokens tokens) {
    final colors = ScenovaColors.of(context);
    return Semantics(
      label: 'Setup panel',
      hint: _revealed ? 'Show the setup steps' : 'Show the walkthrough',
      button: true,
      onTap: _toggle,
      child: SizedBox(
        height: tokens.sizing.buttonHeight,
        child: Center(
          child: SizedBox(
            width: tokens.spacing.xxl,
            height: tokens.spacing.xs,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(ScenovaRadius.full),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
