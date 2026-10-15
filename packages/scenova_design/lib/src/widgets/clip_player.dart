import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/clip_source.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'clip_still_frame.dart';
import 'focus_ring.dart';
import 'scenova_button.dart';

/// What the clip surface is doing.
enum ClipPlayerStatus {
  loading,
  generating,
  stillGenerating,
  ready,
  unavailable,
}

/// The shared Clip Player (`docs/Scenova/screens.md` → "Shared / Common
/// Components").
///
/// A solid-surface card holding the clip, with the word as its caption. It sits
/// over content the product does not own, so it carries a solid surface, never
/// a translucent blur. Clips are muted by default and sound is explicit. When
/// reduce motion is on the clip holds on a still frame and plays on tap.
///
/// A ready clip streams through `video_player`: the surface shows the clip, and
/// the progress line and the play control follow real playback. A source the
/// platform cannot stream — a saved placeholder, say — keeps the still frame
/// instead, so the surface always shows something honest.
///
/// The player is controlled: the host owns whether it is playing and whether
/// sound is on, and is told when playback finishes. A host that also wants the
/// player's own controls sets [controls]; a screen that carries its own action
/// row for the clip leaves them off.
class ClipPlayer extends StatefulWidget {
  const ClipPlayer({
    super.key,
    required this.status,
    required this.caption,
    this.clip,
    this.playing = false,
    this.onTogglePlay,
    this.onToggleSound,
    this.onCompleted,
    this.onRetry,
    this.reduceMotion = false,
    this.soundOn = false,
    this.unavailableMessage,
    this.controls = false,
  });

  /// The clip's frame shape. The clips are generated in a 16:9 frame.
  static const double aspectRatio = 16 / 9;

  /// The clip's own play control, drawn on a still frame. Well above the touch
  /// and pointer minimums, so the one action on an empty frame is unmistakable.
  static const double playAffordanceSize = 64;

  /// The product's four-second clip cap, used as the progress line's length
  /// when the service reports no duration (`C-005`).
  static const Duration fallbackDuration = Duration(seconds: 4);

  final ClipPlayerStatus status;

  /// The word, shown as the clip's caption.
  final String caption;
  final ClipSource? clip;
  final bool playing;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onToggleSound;
  final VoidCallback? onCompleted;
  final VoidCallback? onRetry;
  final bool reduceMotion;
  final bool soundOn;

  /// Replaces the default "no clip" line when the clip is withheld for a
  /// reason other than the word having none.
  final String? unavailableMessage;

  /// Whether the player draws its own Play or Replay and Listen controls, and
  /// the clip's own facts, beneath the frame.
  final bool controls;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer>
    with SingleTickerProviderStateMixin {
  /// Drives the progress line while a clip has no stream to follow.
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _duration,
  )..addStatusListener(_onStatus);

  /// The live stream for a playable clip, or null while none is loaded.
  VideoPlayerController? _video;

  /// The source [_video] was opened against, so a new clip is not re-opened
  /// against the old one.
  Uri? _videoSource;

  /// Whether [_video] has a first frame and can be drawn.
  bool _videoReady = false;

  /// Whether [_video] could not be opened; the still frame stands in with a
  /// retry.
  bool _videoFailed = false;

  /// Whether a stream is being opened, so the frame takes no tap until it is
  /// ready.
  bool _loading = false;

  /// Whether the current playback has already reported completion.
  bool _completionReported = false;

  /// Whether the fallback line is being held at its end under reduce motion.
  /// A hold is not a finish, so it never reports completion.
  bool _holdingStill = false;

  /// Whether the clip has played through, so the control offers a Replay.
  bool _finished = false;

  /// Whether the frame holds keyboard focus, so the ring is drawn.
  bool _focused = false;

  Duration get _duration {
    final seconds = widget.clip?.durationSeconds ?? 0;
    return seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : ClipPlayer.fallbackDuration;
  }

  /// The source a video player can stream, or null.
  static Uri? _playableSource(ClipSource? clip) {
    final url = clip?.url;
    if (url == null || !isPlayableClipUrl(url)) return null;
    return Uri.tryParse(url);
  }

  @override
  void initState() {
    super.initState();
    _syncVideo();
    _applyPlayback();
  }

  void _onStatus(AnimationStatus status) {
    // The fallback line reports completion; a live stream reports its own. A
    // line held at its end under reduce motion is a hold, not a finish.
    if (status == AnimationStatus.completed && !_videoReady && !_holdingStill) {
      _reportCompletion();
    }
  }

  void _reportCompletion() {
    if (!mounted) return;
    setState(() => _finished = true);
    widget.onCompleted?.call();
  }

  @override
  void didUpdateWidget(ClipPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != ClipPlayerStatus.ready) {
      _progress.stop();
      _progress.value = 0;
      _teardownVideo();
      return;
    }
    if (_playableSource(widget.clip) != _playableSource(oldWidget.clip)) {
      _syncVideo();
    }
    if (widget.playing != oldWidget.playing ||
        widget.status != oldWidget.status) {
      // A fresh play offers Play again until this run finishes.
      if (widget.playing && !oldWidget.playing) _finished = false;
      _applyPlayback();
    }
    if (widget.soundOn != oldWidget.soundOn) _applyVolume();
  }

  /// Opens the stream for the current clip, or clears it when there is none.
  void _syncVideo() {
    final source = widget.status == ClipPlayerStatus.ready
        ? _playableSource(widget.clip)
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
    _videoReady = false;
    _videoFailed = false;
    _loading = true;
    _completionReported = false;
    controller.addListener(_onVideoChanged);
    unawaited(_prepare(controller));
  }

  Future<void> _prepare(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      if (!mounted || !identical(_video, controller)) return;
      await controller.setLooping(false);
      await controller.setVolume(widget.soundOn ? 1 : 0);
      if (!mounted || !identical(_video, controller)) return;
      setState(() {
        _videoReady = true;
        _loading = false;
      });
      _applyPlayback();
    } catch (_) {
      // The clip arrived but the stream would not open. The still frame stands
      // in with a retry rather than leaving an empty surface.
      if (!mounted || !identical(_video, controller)) return;
      setState(() {
        _videoReady = false;
        _loading = false;
        _videoFailed = true;
      });
    }
  }

  void _onVideoChanged() {
    final controller = _video;
    if (controller == null || !mounted) return;
    if (controller.value.isCompleted &&
        widget.playing &&
        !_completionReported) {
      _completionReported = true;
      _reportCompletion();
    }
  }

  /// Follows [ClipPlayer.playing] onto the stream, or onto the fallback
  /// progress line when there is no stream to follow.
  void _applyPlayback() {
    final controller = _video;
    if (controller != null && _videoReady) {
      // The stream carries the progress now; the fallback line steps aside.
      if (_progress.isAnimating) _progress.stop();
      if (widget.playing) {
        _completionReported = false;
        unawaited(controller.play());
      } else {
        unawaited(controller.pause());
      }
      return;
    }
    if (widget.playing && !_progress.isAnimating) {
      if (widget.reduceMotion) {
        // Reduce motion holds the still frame: the fallback line shows the clip
        // held at its end rather than animating through it. It is a hold, so it
        // does not report a finish; the reader's own tap ends it.
        _holdingStill = true;
        _progress.value = 1;
      } else {
        _holdingStill = false;
        _progress.forward(from: 0);
      }
    } else if (!widget.playing) {
      // The hold ends with the play; a fresh play starts from the beginning.
      _holdingStill = false;
      if (_progress.isAnimating) _progress.stop();
    }
  }

  void _applyVolume() {
    final controller = _video;
    if (controller == null || !_videoReady) return;
    unawaited(controller.setVolume(widget.soundOn ? 1 : 0));
  }

  /// Reopens the stream after a failed load.
  void _retryVideo() {
    setState(() {
      _videoFailed = false;
      _finished = false;
    });
    _teardownVideo();
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
    _progress.removeStatusListener(_onStatus);
    _progress.dispose();
    _teardownVideo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    // The ring is drawn outside the frame, so the rounded clip of the video
    // does not cut it off.
    final frame = FocusRing(
      visible: _focused,
      radius: ScenovaRadius.md,
      child: AspectRatio(
        aspectRatio: ClipPlayer.aspectRatio,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceSecondary,
            borderRadius: BorderRadius.circular(ScenovaRadius.md),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ScenovaRadius.md),
            child: _surface(context),
          ),
        ),
      ),
    );

    if (!widget.controls) return frame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        frame,
        SizedBox(height: tokens.spacing.sm),
        _controls(context),
      ],
    );
  }

  Widget _surface(BuildContext context) {
    return switch (widget.status) {
      ClipPlayerStatus.loading => const _Message(
        label: 'Finding your clip',
        showProgress: true,
      ),
      ClipPlayerStatus.generating => const _Message(
        label: 'Making your clip',
        showProgress: true,
      ),
      // Past the wait threshold the spinner gives way to a still message; the
      // reader is told the clip is still being made.
      ClipPlayerStatus.stillGenerating => const _Message(
        label: 'Still making your clip',
      ),
      ClipPlayerStatus.unavailable => _Unavailable(
        message: widget.unavailableMessage,
        onRetry: widget.onRetry,
      ),
      ClipPlayerStatus.ready => _readySurface(context),
    };
  }

  Widget _readySurface(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final video = _video;
    final showPlayAffordance = !widget.playing && !_loading && !_videoFailed;
    final muted = (widget.clip?.hasAudio ?? false) && !widget.soundOn;

    return Semantics(
      button: true,
      label: widget.playing
          ? 'Pause clip for ${widget.caption}'
          : 'Play clip for ${widget.caption}',
      // `canRequestFocus: false` keeps this node out of the traversal order
      // while still reporting when the control inside it takes focus.
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (value) => setState(() => _focused = value),
        child: InkWell(
          onTap: _loading ? null : widget.onTogglePlay,
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
              else if (_videoFailed)
                _Unavailable(
                  message: 'This clip could not be loaded.',
                  onRetry: _retryVideo,
                )
              else
                const Center(child: ClipStillFrame()),
              if (showPlayAffordance) Center(child: _playAffordance(context)),
              if (widget.playing && !_videoFailed)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.all(tokens.spacing.sm),
                    child: _progressLine(context),
                  ),
                ),
              if (muted && !_videoFailed)
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(tokens.spacing.sm),
                    child: _chip(
                      context,
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          AppIconView(
                            icon: AppIcons.listen,
                            size: tokens.sizing.iconSm,
                          ),
                          SizedBox(width: tokens.spacing.xs),
                          Text(
                            'Muted',
                            style: styles.caption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (widget.reduceMotion && showPlayAffordance)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(tokens.spacing.sm),
                    child: _chip(
                      context,
                      Text(
                        'Tap to play',
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
  /// above the touch and pointer minimums so it reads as the one action on a
  /// still clip.
  Widget _playAffordance(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Container(
      width: ClipPlayer.playAffordanceSize,
      height: ClipPlayer.playAffordanceSize,
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

  /// A label that sits over the clip, on a solid surface so it stays legible
  /// against whatever frame is playing. A solid surface, never a translucent
  /// blur, is the same rule the in-context card itself follows.
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

  /// The progress line: the real playback position once the stream is up, and
  /// the fallback animation otherwise.
  Widget _progressLine(BuildContext context) {
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

  /// The player's own controls: Play or Replay, Listen when the clip carries
  /// audio, and the clip's facts.
  Widget _controls(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final clip = widget.clip;
    final label = widget.playing
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
          icon: widget.playing
              ? AppIcons.pause
              : _finished
              ? AppIcons.replay
              : AppIcons.play,
          onPressed: _loading ? null : widget.onTogglePlay,
        ),
        if (clip != null && clip.hasAudio) ...<Widget>[
          SizedBox(width: tokens.spacing.sm),
          ScenovaButton(
            label: widget.soundOn ? 'Mute' : 'Listen',
            variant: ScenovaButtonVariant.ghost,
            icon: AppIcons.listen,
            semanticLabel: widget.soundOn
                ? 'Mute the clip'
                : 'Play the clip with sound',
            onPressed: widget.onToggleSound,
          ),
        ],
        SizedBox(width: tokens.spacing.md),
        // The clip's own facts, right-aligned and the first thing to give way
        // when the card is narrow.
        if (clip != null)
          Flexible(
            child: Text(
              '${clip.resolution} · '
              '${_seconds(clip.durationSeconds)}'
              '${widget.reduceMotion ? ' · plays on tap' : ''}',
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

class _Message extends StatelessWidget {
  const _Message({required this.label, this.showProgress = false});

  final String label;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showProgress)
            SizedBox.square(
              dimension: tokens.sizing.iconMd,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.primary,
              ),
            ),
          SizedBox(height: tokens.spacing.sm),
          Text(
            label,
            style: styles.bodySmall.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({this.message, this.onRetry});

  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Center(
      child: Padding(
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
              message ?? 'No clip for this word yet.',
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...<Widget>[
              SizedBox(height: tokens.spacing.md),
              ScenovaButton(
                label: 'Try again',
                onPressed: onRetry,
                variant: ScenovaButtonVariant.outline,
                icon: AppIcons.retry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
