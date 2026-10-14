import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme/colors.dart';

/// The first-run walkthrough (`docs/Scenova/screens/01-onboarding.md` →
/// Declared Assets; `ASSETS.md` → A-010).
///
/// A short, silent clip that shows a word selected on a page and a clip
/// appearing in place — reading first, clip second. It runs full-bleed as the
/// onboarding screen's background, on a seamless loop, behind the setup
/// content (`docs/Scenova/screens/01-onboarding.md` → Layout; `branding.md` →
/// "Motion Direction": the walkthrough opens and closes on the reading page, so
/// its end meets its start with no visible seam).
///
/// The clip is decorative: the setup panel carries the meaning in text, so the
/// background stays out of the semantics tree and never takes a tap. When
/// reduce motion is on it holds on a still frame instead of looping
/// (`docs/Scenova/branding.md` → "Accessibility"). If the clip is still loading
/// or cannot play, the background shows the base surface and the setup content
/// is unchanged.
class FirstRunWalkthrough extends StatefulWidget {
  const FirstRunWalkthrough({super.key, this.reduceMotion = false});

  /// The delivered master (`ASSETS.md` → A-010). Only the walkthrough is
  /// bundled: the store preview is for the store listing, not an in-app surface.
  static const String assetPath = 'assets/motion/first-run-walkthrough.mp4';

  /// When on, the clip holds on a still frame instead of looping.
  final bool reduceMotion;

  @override
  State<FirstRunWalkthrough> createState() => _FirstRunWalkthroughState();
}

class _FirstRunWalkthroughState extends State<FirstRunWalkthrough> {
  VideoPlayerController? _video;

  /// Whether the clip has a first frame and can be drawn.
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(FirstRunWalkthrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion == oldWidget.reduceMotion) return;
    // Reduce motion turned on mid-view: hold the clip where it is. Turned off:
    // resume the seamless loop.
    if (widget.reduceMotion) {
      unawaited(_video?.pause());
    } else {
      _start();
    }
  }

  /// Opens the bundled clip. It ships with the app, so it needs no network and
  /// is on the reader's device from the first launch.
  void _open() {
    final controller = VideoPlayerController.asset(
      FirstRunWalkthrough.assetPath,
    );
    _video = controller;
    unawaited(_prepare(controller));
  }

  Future<void> _prepare(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      if (!mounted || !identical(_video, controller)) return;
      // Silent, and muted so the reader is not startled in public.
      await controller.setVolume(0);
      if (!mounted || !identical(_video, controller)) return;
      setState(() => _ready = true);
      _start();
    } catch (_) {
      // The clip would not open. The background falls back to the base surface
      // and the setup content is unchanged; there is nothing to rebuild.
    }
  }

  /// Runs the clip on a seamless loop, unless reduce motion asks it to hold on
  /// a still frame.
  void _start() {
    final controller = _video;
    if (controller == null || !_ready || widget.reduceMotion) return;
    unawaited(controller.setLooping(true));
    unawaited(controller.play());
  }

  @override
  void dispose() {
    final controller = _video;
    _video = null;
    if (controller != null) {
      unawaited(controller.dispose().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Decorative motion behind the setup panel: the panel's text carries the
    // meaning, so the background is kept out of the semantics tree.
    return ExcludeSemantics(child: _ready ? _clip() : _baseSurface(context));
  }

  /// The clip stretched to cover the whole screen, its aspect ratio kept, so it
  /// is full-bleed on any window shape.
  Widget _clip() {
    final controller = _video!;
    final size = controller.value.size;
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  /// The base surface, shown until a first frame arrives and if the clip cannot
  /// play at all.
  Widget _baseSurface(BuildContext context) => SizedBox.expand(
    child: ColoredBox(color: ScenovaColors.of(context).surface),
  );
}
