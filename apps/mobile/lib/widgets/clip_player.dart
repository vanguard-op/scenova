import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../config.dart';
import '../models/lookup.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'brand_mark.dart';
import 'scenova_button.dart';

/// What the clip surface is doing.
enum ClipPlayerStatus {
  loading,
  generating,
  stillGenerating,
  ready,
  unavailable,
}

/// The shared Clip Player (`docs/Scenova/screens.md`).
///
/// A solid-surface card holding the clip, with the word as its caption. It sits
/// over content the product does not own, so it carries a solid surface, never
/// a translucent blur. Clips are muted by default and sound is explicit. When
/// reduce motion is on the clip holds on a still frame and plays on tap.
///
/// A ready clip streams through `video_player`: the reader sees the clip, and
/// the progress line and Play or Replay follow the real playback position. A
/// source the platform cannot stream — a saved placeholder, say — keeps the
/// still poster instead, so the surface always shows something honest.
class ClipPlayer extends StatefulWidget {
  const ClipPlayer({
    super.key,
    required this.status,
    required this.caption,
    this.clip,
    this.playing = false,
    this.onTogglePlay,
    this.onCompleted,
    this.onRetry,
    this.reduceMotion = false,
    this.soundOn = false,
    this.unavailableMessage,
  });

  final ClipPlayerStatus status;

  /// The word, shown as the clip's caption.
  final String caption;
  final Clip? clip;
  final bool playing;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onCompleted;
  final VoidCallback? onRetry;
  final bool reduceMotion;
  final bool soundOn;

  /// Replaces the default "no clip" line when the clip is withheld for a
  /// reason other than the word having none.
  final String? unavailableMessage;

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

  /// Whether [_video] could not be opened; the poster stands in with a retry.
  bool _videoFailed = false;

  /// Whether the current playback has already reported completion.
  bool _completionReported = false;

  Duration get _duration {
    final seconds = widget.clip?.durationSeconds ?? 0;
    return seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : AppConfig.clipDurationFallback;
  }

  /// The source a video player can stream, or null.
  ///
  /// The product's clips are served over http(s). A saved placeholder or a
  /// scripted source is not a stream, so the surface keeps the still poster
  /// rather than asking the platform to open something it cannot play.
  static Uri? _playableSource(Clip? clip) {
    final raw = clip?.url;
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return (uri.scheme == 'http' || uri.scheme == 'https') ? uri : null;
  }

  @override
  void initState() {
    super.initState();
    _syncVideo();
    _applyPlayback();
  }

  void _onStatus(AnimationStatus status) {
    // The fallback line reports completion; a live stream reports its own.
    if (status == AnimationStatus.completed && !_videoReady) {
      widget.onCompleted?.call();
    }
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
      setState(() => _videoReady = true);
      _applyPlayback();
    } catch (_) {
      // The clip arrived but the stream would not open. The poster stands in
      // with a retry rather than leaving an empty surface.
      if (!mounted || !identical(_video, controller)) return;
      setState(() {
        _videoReady = false;
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
      widget.onCompleted?.call();
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
      _progress.forward(from: 0);
    } else if (!widget.playing && _progress.isAnimating) {
      _progress.stop();
    }
  }

  void _applyVolume() {
    final controller = _video;
    if (controller == null || !_videoReady) return;
    unawaited(controller.setVolume(widget.soundOn ? 1 : 0));
  }

  /// Reopens the stream after a failed load.
  void _retryVideo() {
    setState(() => _videoFailed = false);
    _teardownVideo();
    _syncVideo();
  }

  void _teardownVideo() {
    final controller = _video;
    _video = null;
    _videoSource = null;
    _videoReady = false;
    _videoFailed = false;
    if (controller != null) {
      controller.removeListener(_onVideoChanged);
      unawaited(controller.dispose());
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

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceSecondary,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
          child: switch (widget.status) {
            ClipPlayerStatus.loading => const _Message(
              label: 'Finding your clip',
              showProgress: true,
            ),
            ClipPlayerStatus.generating => const _Message(
              label: 'Making your clip',
              showProgress: true,
            ),
            // Past the wait threshold the spinner gives way to a still message;
            // the reader is told the clip is still being made and offered a
            // notice when it is ready.
            ClipPlayerStatus.stillGenerating => const _Message(
              label: 'Still making your clip',
            ),
            ClipPlayerStatus.unavailable => _Unavailable(
              message: widget.unavailableMessage,
              onRetry: widget.onRetry,
            ),
            ClipPlayerStatus.ready => _readySurface(context),
          },
        ),
      ),
    );
  }

  Widget _readySurface(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final video = _video;
    final showPlayAffordance = !widget.playing;
    final muted = (widget.clip?.hasAudio ?? false) && !widget.soundOn;

    return Semantics(
      button: true,
      label: widget.playing
          ? 'Pause clip for ${widget.caption}'
          : 'Play clip for ${widget.caption}',
      child: InkWell(
        onTap: widget.onTogglePlay,
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
                message: 'This clip could not load.',
                onRetry: _retryVideo,
              )
            else
              Center(child: _poster(context)),
            if (showPlayAffordance && !_videoFailed)
              Center(
                child: AppIconView(
                  icon: AppIcons.play,
                  state: ScenovaIconState.active,
                  size: tokens.sizing.iconLg,
                ),
              ),
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
                  child: _overlayChip(
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
                            color: ScenovaColors.of(context).textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (widget.reduceMotion && showPlayAffordance && !_videoFailed)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.all(tokens.spacing.sm),
                  child: _overlayChip(
                    context,
                    Text(
                      'Tap to play',
                      style: styles.caption.copyWith(
                        color: ScenovaColors.of(context).textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A label that sits over the clip, on a solid surface so it stays legible
  /// against whatever frame is playing. A solid surface, never a translucent
  /// blur, is the same rule the in-context card itself follows.
  Widget _overlayChip(BuildContext context, Widget child) {
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

  Widget _poster(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    return Container(
      padding: EdgeInsets.all(tokens.spacing.md),
      decoration: BoxDecoration(
        color: colors.primaryTint,
        borderRadius: BorderRadius.circular(ScenovaRadius.md),
      ),
      child: BrandMark(size: tokens.sizing.iconLg),
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
