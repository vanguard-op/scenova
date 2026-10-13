import 'package:flutter/material.dart';

import '../config.dart';
import '../models/lookup.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'brand_mark.dart';
import 'scenova_button.dart';

/// What the clip surface is doing.
enum ClipPlayerStatus { loading, generating, ready, unavailable }

/// The shared Clip Player (`docs/Scenova/screens.md`).
///
/// A solid-surface card holding the clip, with the word as its caption. It sits
/// over content the product does not own, so it carries a solid surface, never
/// a translucent blur. Clips are muted by default and sound is explicit. When
/// reduce motion is on the clip holds on a still frame and plays on tap.
///
/// Clip playback itself is not wired: the clip assets and the video pipeline
/// are a later phase, so a ready clip renders a poster and a progress line and
/// reports completion. This is reported rather than faked.
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
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _duration,
  )..addStatusListener(_onStatus);

  Duration get _duration {
    final seconds = widget.clip?.durationSeconds ?? 0;
    return seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : AppConfig.clipDurationFallback;
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onCompleted?.call();
    }
  }

  @override
  void didUpdateWidget(ClipPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != ClipPlayerStatus.ready) {
      _progress.stop();
      _progress.value = 0;
      return;
    }
    if (widget.playing && !_progress.isAnimating) {
      _progress.forward(from: 0);
    } else if (!widget.playing && _progress.isAnimating) {
      _progress.stop();
    }
  }

  @override
  void dispose() {
    _progress.removeStatusListener(_onStatus);
    _progress.dispose();
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
            ClipPlayerStatus.unavailable => _Unavailable(
              message: widget.unavailableMessage,
              onRetry: widget.onRetry,
            ),
            ClipPlayerStatus.ready => _Ready(
              caption: widget.caption,
              playing: widget.playing,
              reduceMotion: widget.reduceMotion,
              muted: (widget.clip?.hasAudio ?? false) && !widget.soundOn,
              progress: _progress,
              onTogglePlay: widget.onTogglePlay,
            ),
          },
        ),
      ),
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
            Icon(
              AppIcons.seeIt,
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

class _Ready extends StatelessWidget {
  const _Ready({
    required this.caption,
    required this.playing,
    required this.reduceMotion,
    required this.muted,
    required this.progress,
    this.onTogglePlay,
  });

  final String caption;
  final bool playing;
  final bool reduceMotion;
  final bool muted;
  final Animation<double> progress;
  final VoidCallback? onTogglePlay;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final showPlayAffordance = !playing;

    return Semantics(
      button: true,
      label: playing ? 'Pause clip for $caption' : 'Play clip for $caption',
      child: InkWell(
        onTap: onTogglePlay,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Center(
              child: Container(
                padding: EdgeInsets.all(tokens.spacing.md),
                decoration: BoxDecoration(
                  color: colors.primaryTint,
                  borderRadius: BorderRadius.circular(ScenovaRadius.md),
                ),
                child: BrandMark(size: tokens.sizing.iconLg),
              ),
            ),
            if (showPlayAffordance)
              Center(
                child: Icon(
                  AppIcons.play,
                  size: tokens.sizing.iconLg,
                  color: colors.primary,
                ),
              ),
            if (playing)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.all(tokens.spacing.sm),
                  child: AnimatedBuilder(
                    animation: progress,
                    builder: (context, child) {
                      return LinearProgressIndicator(
                        value: progress.value,
                        minHeight: tokens.spacing.xs,
                        backgroundColor: colors.border,
                        color: colors.accent.element,
                      );
                    },
                  ),
                ),
              ),
            if (muted)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(tokens.spacing.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        AppIcons.listen,
                        size: tokens.sizing.iconSm,
                        color: colors.textSecondary,
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
            if (reduceMotion && showPlayAffordance)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.all(tokens.spacing.sm),
                  child: Text(
                    'Tap to play',
                    style: styles.caption.copyWith(color: colors.textSecondary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
