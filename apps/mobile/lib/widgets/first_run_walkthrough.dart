import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import 'app_icons.dart';
import 'brand_mark.dart';

/// The first-run walkthrough (`docs/Scenova/screens/01-onboarding.md` →
/// Declared Assets; `ASSETS.md` → A-010).
///
/// A short, silent, one-shot clip that shows a word selected on a page and a
/// clip appearing in place — reading first, clip second. It carries the
/// explanation of what Scenova does across the first-run steps, so it sits
/// beneath the explanation and above the setup controls.
///
/// Motion follows the branding direction: silent, a single pass with no loop,
/// ending held on the reading page. When reduce motion is on it holds on a still
/// frame and plays only on tap; while it plays a tap pauses it, so the reader is
/// never left with motion they did not ask for.
class FirstRunWalkthrough extends StatefulWidget {
  const FirstRunWalkthrough({super.key, this.reduceMotion = false});

  /// The delivered master (`ASSETS.md` → A-010). Only the walkthrough is
  /// bundled: the store preview is for the store listing, not an in-app surface.
  static const String assetPath = 'assets/motion/first-run-walkthrough.mp4';

  /// The delivered clip's shape, portrait 9:16.
  static const double aspectRatio = 9 / 16;

  /// When on, the clip holds on a still frame and plays on tap.
  final bool reduceMotion;

  @override
  State<FirstRunWalkthrough> createState() => _FirstRunWalkthroughState();
}

class _FirstRunWalkthroughState extends State<FirstRunWalkthrough> {
  VideoPlayerController? _video;

  /// Whether the clip has a first frame and can be drawn.
  bool _ready = false;

  bool _playing = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(FirstRunWalkthrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reduce motion turned on mid-view: hold the clip where it is.
    if (widget.reduceMotion && !oldWidget.reduceMotion) {
      unawaited(_video?.pause());
    }
  }

  /// Opens the bundled clip. It ships with the app, so it needs no network and
  /// is on the reader's device from the first launch.
  void _open() {
    final controller = VideoPlayerController.asset(
      FirstRunWalkthrough.assetPath,
    );
    _video = controller;
    controller.addListener(_onVideoChanged);
    unawaited(_prepare(controller));
  }

  Future<void> _prepare(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      if (!mounted || !identical(_video, controller)) return;
      // One pass, no loop, silent: the walkthrough ends held on the reading page.
      await controller.setLooping(false);
      await controller.setVolume(0);
      if (!mounted || !identical(_video, controller)) return;
      setState(() => _ready = true);
      if (!widget.reduceMotion) unawaited(controller.play());
    } catch (_) {
      // The clip would not open. The screen's own text still explains the
      // product, so the surface keeps the mark rather than showing a broken box;
      // there is nothing to rebuild, since the mark is what it shows until a
      // first frame arrives.
    }
  }

  void _onVideoChanged() {
    final controller = _video;
    if (controller == null || !mounted) return;
    final playing = controller.value.isPlaying;
    final completed = controller.value.isCompleted;
    if (playing == _playing && completed == _completed) return;
    setState(() {
      _playing = playing;
      _completed = completed;
    });
  }

  /// Plays, pauses, or replays the clip. The whole card is the target, so the
  /// reader can stop motion they did not ask for and start it again.
  void _toggle() {
    final controller = _video;
    if (controller == null || !_ready) return;
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
      return;
    }
    // Past the end, `play` rewinds first, so the replay starts at the page.
    unawaited(controller.play());
  }

  @override
  void dispose() {
    final controller = _video;
    _video = null;
    if (controller != null) {
      controller.removeListener(_onVideoChanged);
      unawaited(controller.dispose().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    // A phone-sized portrait card: the clip is 9:16 and reads as a phone screen,
    // held to a fraction of the column so it illustrates the flow without
    // competing with the enable-action step the screen leads with.
    return Center(
      child: SizedBox(
        height: tokens.spacing.xxxl * 6,
        child: AspectRatio(
          aspectRatio: FirstRunWalkthrough.aspectRatio,
          child: _card(
            context,
            _ready ? _clip(context) : _placeholder(context),
          ),
        ),
      ),
    );
  }

  /// The card the clip sits in: a solid surface with soft corners, never a
  /// translucent blur, so it holds on both themes.
  Widget _card(BuildContext context, Widget child) {
    final colors = ScenovaColors.of(context);
    final radius = BorderRadius.circular(ScenovaRadius.md);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: radius,
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }

  Widget _clip(BuildContext context) {
    final controller = _video!;
    final tokens = ScenovaTokens.of(context);

    return Semantics(
      button: true,
      label:
          'How Scenova works: a word selected on a page and its clip in place',
      hint: _playing
          ? 'Double tap to pause'
          : _completed
          ? 'Double tap to replay'
          : 'Double tap to play',
      child: Material(
        color: ScenovaPalette.transparent,
        child: InkWell(
          onTap: _toggle,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
              if (!_playing)
                Center(
                  child: Container(
                    padding: EdgeInsets.all(tokens.spacing.sm),
                    decoration: BoxDecoration(
                      color: ScenovaColors.of(context).surface,
                      shape: BoxShape.circle,
                      boxShadow: tokens.shadowSm,
                    ),
                    child: AppIconView(
                      icon: _completed ? AppIcons.replay : AppIcons.play,
                      state: ScenovaIconState.active,
                      size: tokens.sizing.iconMd,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Holds the mark while the clip has no frame to show, so the surface reads as
  /// designed rather than empty.
  Widget _placeholder(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Semantics(
      image: true,
      label: 'The Scenova walkthrough',
      child: Center(
        child: Container(
          padding: EdgeInsets.all(tokens.spacing.md),
          decoration: BoxDecoration(
            color: colors.primaryTint,
            borderRadius: BorderRadius.circular(ScenovaRadius.md),
          ),
          child: BrandMark(size: tokens.sizing.iconLg),
        ),
      ),
    );
  }
}
