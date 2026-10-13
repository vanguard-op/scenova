import 'dart:async';

import 'package:flutter/material.dart';

import '../models/analytics_event.dart';
import '../models/lookup.dart';
import '../services/app_services.dart';
import '../services/settings_controller.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/app_icons.dart';
import '../widgets/clip_player.dart';
import '../widgets/coming_later_sheet.dart';
import '../widgets/offline_banner.dart';
import '../widgets/scenova_button.dart';
import '../widgets/skeleton.dart';
import '../widgets/states.dart';
import '../widgets/word_phrase_header.dart';
import 'clip_controller.dart';

/// How the clip view is presented.
enum ClipPresentation {
  /// A full page inside the app, reached from Home or History.
  page,

  /// A card inside the iOS share extension, over the reading app. The backdrop
  /// is transparent so the reading page stays visible behind the card, and the
  /// copy speaks to closing the extension rather than returning to Home.
  extension,
}

/// Screen 3: Clip View (`docs/Scenova/screens/03-clip-view.md`).
///
/// Shows the selected word or phrase with its clip, in place over the reading
/// app. The card sits near the top on mobile so the reading page stays visible
/// behind it, and centres with a larger clip on tablet. It carries the shared
/// Clip Player, the shared Word and Phrase Header, and the action row.
///
/// Every state from the screen spec is covered: loading, serving from the
/// library, generating, sense choice, playing, fallback, allowance exhausted,
/// offline, and error.
class ClipViewScreen extends StatefulWidget {
  const ClipViewScreen({
    super.key,
    required this.controller,
    this.presentation = ClipPresentation.page,
    this.onDismiss,
    this.onOpenHistory,
  });

  final ClipViewController controller;

  /// Where the view is being shown; the extension presentation drops the
  /// opaque backdrop and adapts the copy.
  final ClipPresentation presentation;
  final VoidCallback? onDismiss;
  final VoidCallback? onOpenHistory;

  @override
  State<ClipViewScreen> createState() => _ClipViewScreenState();
}

class _ClipViewScreenState extends State<ClipViewScreen> {
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  bool _hasPlayed = false;
  bool _noticeQueued = false;

  ClipViewController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notice = _controller.selection.notice;
      if (notice != null) _showMessage(notice);
    });
    _controller.load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_controller.playing) _hasPlayed = true;
    setState(() {});
    if (_controller.shouldShowGeneratingNotice && !_noticeQueued) {
      _noticeQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _noticeQueued = false;
        // The clip may have become ready between the change and this frame; the
        // notice is only raised while generation is still past the threshold.
        if (_controller.shouldShowGeneratingNotice) _showGeneratingNotice();
      });
    }
  }

  void _showMessage(String message) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showGeneratingNotice() {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'Your clip is still being made. It will be here shortly.',
          ),
          action: SnackBarAction(
            label: 'Notify me',
            onPressed: () => unawaited(_notifyWhenReady()),
          ),
        ),
      );
    _controller.markGeneratingNoticeShown();
  }

  /// Registers the device for the clip-ready notice and tells the reader
  /// whether it was set up.
  Future<void> _notifyWhenReady() async {
    final registered = await _controller.notifyWhenReady();
    if (!mounted) return;
    _showMessage(
      registered
          ? "We'll let you know when your clip is ready."
          : 'We could not set up the notice. Try again when you are online.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final centered = tokens.deviceClass.isTablet;
    final inExtension = widget.presentation == ClipPresentation.extension;

    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        // The extension sits over the reading app, so only the card is painted;
        // the page shows through everywhere else.
        backgroundColor: inExtension ? ScenovaPalette.transparent : null,
        body: SafeArea(
          child: Align(
            alignment: centered ? Alignment.center : Alignment.topCenter,
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.lg,
                vertical: tokens.spacing.xl,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: centered ? 560 : 480),
                child: Container(
                  padding: EdgeInsets.all(tokens.spacing.lg),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(ScenovaRadius.lg),
                    boxShadow: tokens.shadowLg,
                  ),
                  child: _content(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final inExtension = widget.presentation == ClipPresentation.extension;
    switch (_controller.phase) {
      case ClipPhase.loading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _heading(context),
            SizedBox(height: tokens.spacing.lg),
            ClipPlayer(
              status: ClipPlayerStatus.loading,
              caption: _controller.word,
            ),
            SizedBox(height: tokens.spacing.md),
            const SkeletonList(rows: 2),
          ],
        );

      case ClipPhase.empty:
        return EmptyState(
          icon: AppIcons.search,
          headline: 'Nothing to look up',
          body: inExtension
              ? 'Select a word in a reading app and choose Scenova.'
              : 'Select a word in a reading app, or type one on Home.',
          actionLabel: inExtension ? 'Close' : 'Back to Home',
          onAction: widget.onDismiss,
        );

      case ClipPhase.offline:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const OfflineBanner(
              message:
                  'You are offline. New clips need a connection; saved ones '
                  'still play.',
            ),
            SizedBox(height: tokens.spacing.lg),
            EmptyState(
              icon: AppIcons.offline,
              headline: 'This word is not saved on this device',
              body: inExtension
                  ? 'Look it up again when you are back online.'
                  : 'Look it up again when you are back online, or browse the '
                        'lookups you have saved.',
              actionLabel: inExtension ? 'Close' : 'Open History',
              onAction: inExtension ? widget.onDismiss : widget.onOpenHistory,
            ),
          ],
        );

      case ClipPhase.error:
        return ErrorState(
          headline: 'That lookup did not finish',
          body: _controller.errorMessage ?? 'Something went wrong.',
          onRetry: _controller.retry,
        );

      case ClipPhase.senseChoice:
        return _senseChoice(context);

      case ClipPhase.denied:
        return _withHeaderAndActions(
          context,
          player: ClipPlayer(
            status: ClipPlayerStatus.unavailable,
            caption: _controller.word,
            unavailableMessage: 'Model processing is off.',
          ),
          note:
              'Model processing is off, so no new clip was made. Library '
              'lookups and your saved clips still work.',
          action: ScenovaButton(
            label: 'Turn on model processing',
            variant: ScenovaButtonVariant.secondary,
            onPressed: _enableConsent,
          ),
        );

      case ClipPhase.allowanceExhausted:
        return _withHeaderAndActions(
          context,
          player: ClipPlayer(
            status: ClipPlayerStatus.unavailable,
            caption: _controller.word,
            unavailableMessage: 'A plan unlocks this clip.',
          ),
          note:
              'You have used this month\'s lookups. A plan brings more clips.',
          action: ScenovaButton(
            label: 'See plans',
            variant: ScenovaButtonVariant.primary,
            onPressed: () => showComingLaterSheet(
              context,
              title: 'Plans',
              message:
                  'Pro and top-ups arrive with the account phase. Nothing is '
                  'charged until then.',
            ),
          ),
        );

      case ClipPhase.fallback:
        return _withHeaderAndActions(
          context,
          player: ClipPlayer(
            status: ClipPlayerStatus.unavailable,
            caption: _controller.word,
            onRetry: _controller.retry,
          ),
        );

      case ClipPhase.generating:
        return _withHeaderAndActions(
          context,
          player: ClipPlayer(
            // Past the wait threshold the progress state gives way to the
            // still "still being made" surface.
            status: _controller.pastWaitThreshold
                ? ClipPlayerStatus.stillGenerating
                : ClipPlayerStatus.generating,
            caption: _controller.word,
          ),
        );

      case ClipPhase.playing:
        return _withHeaderAndActions(
          context,
          player: ClipPlayer(
            status: ClipPlayerStatus.ready,
            caption: _controller.word,
            clip: _controller.clip,
            playing: _controller.playing,
            onTogglePlay: _controller.togglePlay,
            onCompleted: _controller.onPlaybackCompleted,
            reduceMotion: _settings.reduceMotion,
            soundOn: _settings.soundOn,
          ),
        );
    }
  }

  /// The shared shape for the phases that show a clip surface: the word
  /// heading, the clip player, the shared Word and Phrase Header, and the
  /// action row.
  Widget _withHeaderAndActions(
    BuildContext context, {
    required Widget player,
    String? note,
    Widget? action,
  }) {
    final tokens = ScenovaTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _heading(context),
        SizedBox(height: tokens.spacing.lg),
        player,
        SizedBox(height: tokens.spacing.lg),
        WordPhraseHeader(
          word: _controller.word,
          phrase: _controller.phrase,
          note: note ?? _controller.note,
          compact: true,
        ),
        if (action != null) ...<Widget>[
          SizedBox(height: tokens.spacing.lg),
          action,
        ],
        SizedBox(height: tokens.spacing.lg),
        _actions(context),
      ],
    );
  }

  Widget _heading(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              _controller.word,
              style: styles.h3.copyWith(color: colors.textPrimary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        ScenovaIconButton(
          icon: AppIcons.close,
          tooltip: 'Close',
          onPressed: widget.onDismiss,
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    final settings = _settings;
    final clip = _controller.clip;
    final canPlay = _controller.phase == ClipPhase.playing;
    final feedback = _controller.feedback;
    final showListen = canPlay && (clip?.hasAudio ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (canPlay || showListen) ...<Widget>[
          Wrap(
            spacing: tokens.spacing.sm,
            runSpacing: tokens.spacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (canPlay)
                ScenovaIconButton(
                  icon: _controller.playing
                      ? AppIcons.pause
                      : (_hasPlayed ? AppIcons.replay : AppIcons.play),
                  tooltip: _controller.playing
                      ? 'Pause'
                      : (_hasPlayed ? 'Replay' : 'Play'),
                  active: _controller.playing,
                  onPressed: _controller.togglePlay,
                ),
              if (showListen)
                ScenovaIconButton(
                  icon: AppIcons.listen,
                  tooltip: settings.soundOn ? 'Mute' : 'Listen',
                  active: settings.soundOn,
                  onPressed: () {
                    settings.soundOn = !settings.soundOn;
                    ScenovaScope.of(context).analytics.preferenceChanged(
                      setting: AnalyticsSetting.sound,
                      value: settings.soundOn,
                    );
                  },
                ),
              ScenovaIconButton(
                icon: AppIcons.helpful,
                tooltip: 'This showed the meaning',
                active: feedback == FeedbackMark.helpful,
                onPressed: () => _controller.markFeedback(FeedbackMark.helpful),
              ),
              ScenovaIconButton(
                icon: AppIcons.notHelpful,
                tooltip: 'This did not show the meaning',
                active: feedback == FeedbackMark.notHelpful,
                onPressed: () =>
                    _controller.markFeedback(FeedbackMark.notHelpful),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.sm),
        ],
        Wrap(
          spacing: tokens.spacing.sm,
          runSpacing: tokens.spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            ScenovaButton(
              label: 'Report',
              variant: ScenovaButtonVariant.ghost,
              onPressed: () => showComingLaterSheet(
                context,
                title: 'Report this clip',
                message:
                    'Reporting arrives with the review phase. Until then, '
                    'marking the clip not helpful still records your view.',
              ),
            ),
            // History is an app destination; the extension presentation has
            // nowhere to open it, so the action is left out there.
            if (widget.presentation != ClipPresentation.extension)
              ScenovaButton(
                label: 'History',
                variant: ScenovaButtonVariant.ghost,
                onPressed: widget.onOpenHistory,
              ),
          ],
        ),
        if (feedback != null) ...<Widget>[
          SizedBox(height: tokens.spacing.sm),
          Semantics(
            liveRegion: true,
            child: Text(
              'Thanks — noted.',
              style: styles.caption.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ],
    );
  }

  Widget _senseChoice(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    final senses = _controller.result?.senses ?? const <Sense>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _heading(context),
        SizedBox(height: tokens.spacing.sm),
        Text(
          'Which meaning fits here?',
          style: styles.body.copyWith(color: colors.textSecondary),
        ),
        SizedBox(height: tokens.spacing.lg),
        for (final sense in senses) ...<Widget>[
          _SenseCard(
            sense: sense,
            onChoose: () => _controller.chooseSense(sense),
          ),
          SizedBox(height: tokens.spacing.md),
        ],
        _actions(context),
      ],
    );
  }

  void _enableConsent() {
    _settings.consentModelProcessing = true;
    ScenovaScope.of(context).analytics.consentChanged(consent: true);
    _controller.retry();
  }

  SettingsController get _settings => ScenovaScope.of(context).settings;
}

/// A one-sense option in the sense chooser: its clip with its phrase, for the
/// reader to pick the meaning that fits.
class _SenseCard extends StatelessWidget {
  const _SenseCard({required this.sense, required this.onChoose});

  final Sense sense;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return InkWell(
      onTap: onChoose,
      borderRadius: BorderRadius.circular(ScenovaRadius.lg),
      child: Container(
        padding: EdgeInsets.all(tokens.spacing.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ScenovaRadius.lg),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipPlayer(
              status: ClipPlayerStatus.ready,
              caption: sense.glossPhrase,
              clip: sense.clip,
              onTogglePlay: onChoose,
            ),
            SizedBox(height: tokens.spacing.md),
            Text(
              sense.glossPhrase,
              style: styles.bodyLarge.copyWith(color: colors.textPrimary),
            ),
            if (sense.partOfSpeech.isNotEmpty) ...<Widget>[
              SizedBox(height: tokens.spacing.xs),
              Text(
                sense.partOfSpeech,
                style: styles.caption.copyWith(color: colors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
