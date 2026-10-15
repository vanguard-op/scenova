import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/review_entry.dart';
import '../theme/colors.dart';
import '../theme/layout.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'focus_ring.dart';
import 'scenova_button.dart';

/// The shared Clip Player on the Review Entry screen
/// (`docs/Scenova/screens.md` → "Shared / Common Components").
///
/// A solid-surface frame holding the clip, so the curator judges the clip
/// itself and not a description of it. Clips are muted by default and sound is
/// explicit; under reduce motion the clip holds on a still frame and plays only
/// on tap.
///
/// A clip the platform can stream opens through `video_player`, so the progress
/// line and the controls follow real playback. A source the platform cannot
/// stream — the development service's scripted placeholder, say — keeps the
/// still frame and steps a fallback line through the clip's own duration, so
/// the surface always shows something honest.
class ClipPlayer extends StatefulWidget {
  const ClipPlayer({super.key, required this.caption, required this.clip});

  /// The word, shown as the clip's caption by the card around it.
  final String caption;

  final ReviewClip clip;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer>
    with SingleTickerProviderStateMixin {
  /// Drives the progress line while a clip has no stream to follow.
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _fallbackDuration,
  )..addStatusListener(_onProgressStatus);

  VideoPlayerController? _video;
  Uri? _videoSource;
  bool _videoReady = false;
  bool _videoFailed = false;
  bool _loading = false;
  bool _playing = false;
  bool _finished = false;
  bool _soundOn = false;
  bool _focused = false;

  /// The clip's own duration, or the product's four-second cap when the service
  /// reports none (`C-005`: clips are capped at four seconds).
  Duration get _fallbackDuration {
    final seconds = widget.clip.durationSeconds;
    return seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : const Duration(seconds: 4);
  }

  @override
  void initState() {
    super.initState();
    _syncVideo();
  }

  @override
  void didUpdateWidget(ClipPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.clip.url != oldWidget.clip.url) {
      _playing = false;
      _finished = false;
      _progress.value = 0;
      _syncVideo();
    }
  }

  void _onProgressStatus(AnimationStatus status) {
    // The fallback line reports its own completion, since there is no stream.
    if (status == AnimationStatus.completed && mounted) {
      setState(() {
        _playing = false;
        _finished = true;
      });
    }
  }

  /// Opens the stream for the current clip, or clears it when there is none.
  void _syncVideo() {
    final source = widget.clip.isPlayable
        ? Uri.tryParse(widget.clip.url)
        : null;
    if (source == null) {
      _teardownVideo();
      return;
    }
    if (_video != null && _videoSource == source) return;
    _teardownVideo();

    final controller = VideoPlayerController.networkUrl(source);
    _video = controller;
    _videoSource = source;
    _loading = true;
    controller.addListener(_onVideoChanged);
    unawaited(_prepare(controller));
  }

  Future<void> _prepare(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      if (!mounted || !identical(_video, controller)) return;
      await controller.setLooping(false);
      await controller.setVolume(_soundOn ? 1 : 0);
      if (!mounted || !identical(_video, controller)) return;
      setState(() {
        _videoReady = true;
        _loading = false;
      });
    } catch (_) {
      // The clip arrived but the stream would not open. The still frame stands
      // in with a retry rather than leaving an empty surface.
      if (!mounted || !identical(_video, controller)) return;
      setState(() {
        _videoFailed = true;
        _loading = false;
      });
    }
  }

  void _onVideoChanged() {
    final controller = _video;
    if (controller == null || !mounted || !_playing) return;
    if (controller.value.isCompleted) {
      setState(() {
        _playing = false;
        _finished = true;
      });
    }
  }

  /// Reopens the stream after a failed load.
  void _retryVideo() {
    setState(() {
      _videoFailed = false;
      _playing = false;
      _finished = false;
    });
    _syncVideo();
  }

  void _teardownVideo() {
    final controller = _video;
    _video = null;
    _videoSource = null;
    _videoReady = false;
    _videoFailed = false;
    _loading = false;
    if (controller != null) {
      controller.removeListener(_onVideoChanged);
      unawaited(_disposeQuietly(controller));
    }
  }

  /// Disposes a player whose platform may never have been attached (a test
  /// binding, say), so teardown never throws.
  Future<void> _disposeQuietly(VideoPlayerController controller) async {
    try {
      await controller.dispose();
    } catch (_) {
      // Nothing to release.
    }
  }

  @override
  void dispose() {
    _progress.removeStatusListener(_onProgressStatus);
    _progress.dispose();
    _teardownVideo();
    super.dispose();
  }

  void _togglePlay() {
    if (_loading) return;
    setState(() {
      if (_playing) {
        _playing = false;
        if (_videoReady) {
          unawaited(_video?.pause());
        } else {
          _progress.stop();
        }
        return;
      }
      _playing = true;
      _finished = false;
      if (_videoReady) {
        unawaited(_video?.play());
      } else if (MediaQuery.disableAnimationsOf(context)) {
        // Reduce motion holds the still frame: the fallback line jumps to its
        // end rather than animating.
        _progress.value = 1;
      } else {
        _progress.forward(from: 0);
      }
    });
  }

  void _toggleSound() {
    setState(() {
      _soundOn = !_soundOn;
      if (_videoReady) unawaited(_video?.setVolume(_soundOn ? 1 : 0));
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The ring is drawn outside the frame, so the rounded clip of the
        // video does not cut it off.
        FocusRing(
          visible: _focused,
          radius: ScenovaRadius.md,
          child: AspectRatio(
            aspectRatio: ConsoleLayout.clipAspectRatio,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceSecondary,
                borderRadius: BorderRadius.circular(ScenovaRadius.md),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(ScenovaRadius.md),
                child: _surface(context, reduceMotion: reduceMotion),
              ),
            ),
          ),
        ),
        SizedBox(height: tokens.spacing.sm),
        _controls(context, reduceMotion: reduceMotion),
      ],
    );
  }

  Widget _surface(BuildContext context, {required bool reduceMotion}) {
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final colors = ScenovaColors.of(context);
    final video = _video;
    final muted = widget.clip.hasAudio && !_soundOn;

    return Semantics(
      button: true,
      label: _playing
          ? 'Pause the clip for ${widget.caption}'
          : 'Play the clip for ${widget.caption}',
      // `canRequestFocus: false` keeps this node out of the traversal order
      // while still reporting when the control inside it takes focus.
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (value) => setState(() => _focused = value),
        child: InkWell(
          onTap: _loading ? null : _togglePlay,
          focusColor: Colors.transparent,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (_videoReady && video != null)
                Center(
                  child: AspectRatio(
                    aspectRatio: video.value.aspectRatio,
                    child: VideoPlayer(video),
                  ),
                )
              else if (_loading)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SizedBox.square(
                        dimension: tokens.sizing.iconMd,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      ),
                      SizedBox(height: tokens.spacing.sm),
                      Text(
                        'Loading the clip',
                        style: styles.bodySmall.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              else if (_videoFailed)
                Center(child: _failed(context))
              else
                // No stream to follow: the frame holds still and the play
                // affordance is the whole surface, so the control never collides
                // with the frame's content.
                Center(child: _playAffordance(context)),
              if (_playing)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.all(tokens.spacing.sm),
                    child: _progressLine(context, reduceMotion: reduceMotion),
                  ),
                ),
              if (muted && !_videoFailed)
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(tokens.spacing.sm),
                    child: _chip(
                      context,
                      Text(
                        'Muted',
                        style: styles.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              if (reduceMotion && !_playing && !_loading && !_videoFailed)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(tokens.spacing.sm),
                    child: _chip(
                      context,
                      Text(
                        'Plays on tap',
                        style: styles.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The frame's own play control: a solid circle on the frame, sized well
  /// above the pointer minimum so it reads as the one action on a still clip.
  Widget _playAffordance(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Container(
      width: ConsoleLayout.clipPlayAffordanceSize,
      height: ConsoleLayout.clipPlayAffordanceSize,
      decoration: BoxDecoration(
        color: colors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: colors.border),
        boxShadow: tokens.shadowSm,
      ),
      child: Center(
        child: AppIconView(
          icon: _finished ? AppIcons.replay : AppIcons.play,
          state: ScenovaIconState.active,
          size: tokens.sizing.iconMd,
        ),
      ),
    );
  }

  /// A label over the clip, on a solid surface so it stays legible against
  /// whatever frame is behind it — the same rule the in-context card follows.
  Widget _chip(BuildContext context, Widget child) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.sm,
        vertical: tokens.spacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(ScenovaRadius.sm),
      ),
      child: child,
    );
  }

  Widget _failed(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Padding(
      padding: EdgeInsets.all(tokens.spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppIconView(
            icon: AppIcons.seeIt,
            size: tokens.sizing.iconMd,
            color: colors.iconDefault,
          ),
          SizedBox(height: tokens.spacing.sm),
          Text(
            'This clip could not be loaded.',
            style: styles.bodySmall.copyWith(color: colors.textSecondary),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: tokens.spacing.md),
          ScenovaButton(
            label: 'Try again',
            variant: ScenovaButtonVariant.outline,
            icon: AppIcons.retry,
            onPressed: _retryVideo,
          ),
        ],
      ),
    );
  }

  /// The progress line: the real playback position once the stream is up, and
  /// the fallback line otherwise.
  Widget _progressLine(BuildContext context, {required bool reduceMotion}) {
    final video = _video;
    if (_videoReady && video != null) {
      return ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: video,
        builder: (context, value, _) {
          final total = value.duration.inMilliseconds;
          final progress = total <= 0
              ? 0.0
              : (value.position.inMilliseconds / total)
                    .clamp(0.0, 1.0)
                    .toDouble();
          return _progressBar(context, progress);
        },
      );
    }
    if (reduceMotion) return _progressBar(context, _playing ? 1 : 0);
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) => _progressBar(context, _progress.value),
    );
  }

  Widget _progressBar(BuildContext context, double value) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    return LinearProgressIndicator(
      value: value,
      minHeight: tokens.spacing.xs,
      backgroundColor: colors.border,
      color: colors.accent.element,
    );
  }

  Widget _controls(BuildContext context, {required bool reduceMotion}) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final clip = widget.clip;
    final label = _playing
        ? 'Pause'
        : _finished
        ? 'Replay'
        : 'Play';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        ScenovaButton(
          label: label,
          variant: ScenovaButtonVariant.outline,
          icon: _playing
              ? AppIcons.pause
              : _finished
              ? AppIcons.replay
              : AppIcons.play,
          onPressed: _loading ? null : _togglePlay,
        ),
        if (clip.hasAudio) ...<Widget>[
          SizedBox(width: tokens.spacing.sm),
          ScenovaButton(
            label: _soundOn ? 'Mute' : 'Listen',
            variant: ScenovaButtonVariant.ghost,
            icon: AppIcons.listen,
            semanticLabel: _soundOn
                ? 'Mute the clip'
                : 'Play the clip with sound',
            onPressed: _toggleSound,
          ),
        ],
        SizedBox(width: tokens.spacing.md),
        // The clip's own facts, right-aligned and the first thing to give way
        // when the card is narrow.
        Flexible(
          child: Text(
            '${clip.resolution} · '
            '${_seconds(clip.durationSeconds)}'
            '${reduceMotion ? ' · plays on tap' : ''}',
            style: styles.caption.copyWith(color: colors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  static String _seconds(double durationSeconds) {
    final rounded = durationSeconds.round();
    return rounded <= 1 ? '1 second' : '$rounded seconds';
  }
}
