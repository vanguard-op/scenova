import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../models/analytics_event.dart';
import '../models/feedback.dart';
import '../models/lookup.dart';
import '../models/report.dart';
import '../services/app_services.dart';
import '../services/capture_intake.dart';
import '../services/push_registrar.dart';
import '../services/settings_controller.dart';
import '../widgets/paywall_sheet.dart';
import '../widgets/report_sheet.dart';
import 'clip_controller.dart';

/// How the clip view is presented.
enum ClipPresentation {
  /// A full page inside the app, reached from Home or History.
  page,

  /// A compact card shown in place over the reading app — the Android
  /// selection action's own surface, or the iOS share extension's sheet. The
  /// backdrop is transparent so the reading page stays visible behind the card,
  /// the copy speaks to closing rather than returning to Home, and there is no
  /// History destination to open.
  inPlace,
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

  /// Where the view is being shown; an in-place presentation drops the opaque
  /// backdrop and adapts the copy to the reading app being one tap away.
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

  /// Whether the reader has opened the action row's overflow, so the actions
  /// the card holds beyond the row's four controls are on screen.
  bool _actionsRevealed = false;

  /// The settings controller this screen is listening to, so a change to the
  /// clip's sound or the motion preference redraws the card.
  SettingsController? _listenedSettings;

  /// Whether the still-making notice is on screen, so it can be taken down the
  /// moment the clip arrives rather than lingering over the clip.
  bool _generatingNoticeVisible = false;

  ClipViewController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The "pick a shorter phrase" state carries the notice itself.
      if (_controller.phase == ClipPhase.selectionTooLong) return;
      final notice = _controller.selection.notice;
      if (notice != null) _showMessage(notice);
    });
    _controller.load();
  }

  @override
  void dispose() {
    _listenedSettings?.removeListener(_onSettingsChanged);
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The card draws the clip's sound and the reader's motion preference from
    // the settings, so a change to either redraws it: the Listen control has to
    // become Mute the moment it is pressed. The scope is read here rather than
    // in initState, where it is not yet safe to depend on.
    final settings = _settings;
    if (identical(settings, _listenedSettings)) return;
    _listenedSettings?.removeListener(_onSettingsChanged);
    _listenedSettings = settings..addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_controller.playing) _hasPlayed = true;
    // The revealed actions belong to the clip on screen: a lookup that settles
    // some other way closes them with it.
    if (_controller.phase != ClipPhase.playing) _actionsRevealed = false;
    setState(() {});
    // The clip has arrived (or the lookup settled some other way), so the
    // still-making notice has nothing left to wait on; it leaves with the wait.
    if (_generatingNoticeVisible && _controller.phase != ClipPhase.generating) {
      _generatingNoticeVisible = false;
      _messengerKey.currentState?.hideCurrentSnackBar();
    }
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

  void _showMessage(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _generatingNoticeVisible = false;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: (actionLabel == null || onAction == null)
              ? null
              : SnackBarAction(label: actionLabel, onPressed: onAction),
        ),
      );
  }

  void _showGeneratingNotice() {
    _generatingNoticeVisible = true;
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

  /// Registers the device for the clip-ready notice and tells the reader what
  /// came of it.
  Future<void> _notifyWhenReady() async {
    final outcome = await _controller.notifyWhenReady();
    if (!mounted) return;
    switch (outcome) {
      case PushNoticeResult.registered:
        _showMessage("We'll let you know when your clip is ready.");
      // The service had nothing left to watch: the lookup has resolved, so the
      // view is about to settle instead of waiting on a notice.
      case PushNoticeResult.noNoticeNeeded:
        _showMessage('This lookup already finished. It will update here.');
      // A refusal is not a connectivity problem, so the reader is told what
      // actually happened rather than sent to try again later.
      case PushNoticeResult.notificationsDenied:
        _showMessage(
          'Notifications are off, so we cannot send a heads-up. You can turn '
          'them on any time.',
        );
      case PushNoticeResult.notificationsPermanentlyDenied:
        _showMessage(
          'Notifications are off for Scenova. Turn them on in your phone '
          'settings to get a heads-up.',
          actionLabel: 'Settings',
          onAction: _openNotificationSettings,
        );
      case PushNoticeResult.notRegistered:
        _showMessage(
          'We could not set up the notice. Try again when you are online.',
        );
    }
  }

  /// Opens the device settings where a refused notification permission is
  /// changed, for the reader who refused it for good.
  void _openNotificationSettings() {
    unawaited(ScenovaScope.of(context).notificationPermission.openSettings());
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final centered = tokens.deviceClass.isTablet;
    final inPlace = widget.presentation == ClipPresentation.inPlace;

    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        // An in-place view sits over the reading app, so only the card is
        // painted; the page shows through everywhere else.
        backgroundColor: inPlace ? ScenovaPalette.transparent : null,
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
    final inPlace = widget.presentation == ClipPresentation.inPlace;
    final isPhrase = _controller.isPhrase;
    switch (_controller.phase) {
      case ClipPhase.loading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(context),
            SizedBox(height: tokens.spacing.lg),
            ClipPlayer(
              status: ClipPlayerStatus.loading,
              caption: _controller.word,
            ),
            SizedBox(height: tokens.spacing.lg),
            // The word is known as soon as the selection is; the phrase it will
            // be shown with is what the lookup is still resolving.
            WordPhraseHeader(word: _controller.word, compact: true),
            SizedBox(height: tokens.spacing.md),
            const SkeletonList(rows: 1),
          ],
        );

      case ClipPhase.empty:
        return EmptyState(
          icon: AppIcons.search,
          headline: 'Nothing to look up',
          body: inPlace
              ? 'Select a word in a reading app and choose Scenova.'
              : 'Select a word in a reading app, or type one on Home.',
          actionLabel: inPlace ? 'Close' : 'Back to Home',
          onAction: widget.onDismiss,
        );

      case ClipPhase.selectionTooLong:
        // A selection over the phrase limit starts no lookup; the reader is
        // asked to narrow it (`FEAT-007`). The gate's own message says what
        // Scenova handles; a selection held back for its length is told how
        // long it was.
        final selection = _controller.selection;
        return EmptyState(
          icon: AppIcons.search,
          headline: 'Pick a shorter phrase',
          body: selection.limit == SelectionLimit.words
              ? '${selection.notice} Your selection was '
                    '${selection.truncatedFrom} words. Select up to six and '
                    'open Scenova again.'
              : '${selection.notice} Select a shorter one and open Scenova '
                    'again.',
          actionLabel: inPlace ? 'Close' : 'Back to Home',
          onAction: widget.onDismiss,
        );

      case ClipPhase.offline:
        final replayPaused = !_controller.offlineReplayEnabled;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OfflineBanner(
              message: replayPaused
                  ? 'You are offline. Saved clips need a connection to play.'
                  : 'You are offline. New clips need a connection; saved ones '
                        'still play.',
            ),
            SizedBox(height: tokens.spacing.lg),
            if (_controller.replayingSavedEntry)
              // Offline replay is switched off (`enable_offline_history`): the
              // saved word and phrase stay on the device and are shown, while
              // the clip waits for a connection.
              _withHeaderAndActions(
                context,
                player: ClipPlayer(
                  status: ClipPlayerStatus.unavailable,
                  caption: _controller.word,
                  unavailableMessage: 'Saved clips need a connection to play.',
                  onRetry: _controller.retry,
                ),
              )
            else
              EmptyState(
                icon: AppIcons.offline,
                headline: replayPaused
                    ? 'You are offline'
                    : isPhrase
                    ? 'This phrase is not saved on this device'
                    : 'This word is not saved on this device',
                body: replayPaused
                    ? 'Saved clips need a connection to play. Your history is '
                          'still here.'
                    : isPhrase
                    ? 'A phrase clip needs a connection to be made. Look it up '
                          'again when you are back online.'
                    : inPlace
                    ? 'Look it up again when you are back online.'
                    : 'Look it up again when you are back online, or browse the '
                          'lookups you have saved.',
                actionLabel: inPlace ? 'Close' : 'Open History',
                onAction: inPlace ? widget.onDismiss : widget.onOpenHistory,
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
        // The word and phrase still show; no clip is generated until the
        // allowance is restored. With the paid tier killed the Paywall is hidden
        // and the reader keeps reading without a clip (`enable_paid_tier`).
        final paywall = _paywallEnabled;
        return _withHeaderAndActions(
          context,
          player: ClipPlayer(
            status: ClipPlayerStatus.unavailable,
            caption: _controller.word,
            unavailableMessage: paywall
                ? 'A plan unlocks this clip.'
                : 'No clip this month.',
          ),
          note: paywall
              ? 'You have used this month\'s lookups. A plan brings more clips.'
              : 'You have used this month\'s lookups. They reset next month.',
          action: paywall ? _plansAction(context) : null,
        );

      case ClipPhase.wordAndPhrase:
        return _wordAndPhrase(context);

      case ClipPhase.fallback:
        return _withHeaderAndActions(
          context,
          player: ClipPlayer(
            status: ClipPlayerStatus.unavailable,
            caption: _controller.word,
            unavailableMessage:
                _controller.clipUnavailableMessage ??
                (isPhrase ? 'No clip for this phrase yet.' : null),
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

  /// The shared shape for the phases that show a clip surface: the card
  /// header, the clip player, the shared Word and Phrase Header, and the
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
        _header(context),
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

  /// The word and its phrase with no clip, shown while the in-context view is
  /// switched off at runtime (`enable_clip_view`).
  Widget _wordAndPhrase(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _header(context),
        SizedBox(height: tokens.spacing.lg),
        WordPhraseHeader(
          word: _controller.word,
          phrase: _controller.phrase,
          note: _controller.note,
          compact: true,
        ),
        SizedBox(height: tokens.spacing.md),
        Text(
          'Clips are paused right now. The word and its meaning are still here.',
          style: styles.bodySmall.copyWith(color: colors.textSecondary),
        ),
        SizedBox(height: tokens.spacing.lg),
        _actions(context),
      ],
    );
  }

  /// The card's header: the product's own name, static, so the row reads as
  /// the card's header rather than repeating the word already carried by the
  /// Word and Phrase Header below. The close control aligns to it.
  Widget _header(BuildContext context) {
    final styles = ScenovaTextStyles.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Semantics(header: true, child: BrandLockup(style: styles.h3)),
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
    final settings = _settings;
    final clip = _controller.clip;
    // An action names the clip on screen, so the controls that act on one are
    // offered only while a clip is playing (`FEAT-010`, `FEAT-011`).
    final canPlay = _controller.phase == ClipPhase.playing;
    final feedback = _controller.feedback;
    final soundOn = settings.soundOn;
    final showListen = canPlay && (clip?.hasAudio ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (canPlay) ...<Widget>[
          // The row shows four controls — play or replay, listen or mute, and
          // the two the reader judges the clip with — however many actions the
          // card grows. Anything further is reached through the overflow beside
          // them, so the row keeps its shape and Report stays reachable.
          Wrap(
            spacing: tokens.spacing.sm,
            runSpacing: tokens.spacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
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
                  // The icon names the clip's sound as it stands; the tooltip
                  // names what the control does about it.
                  icon: soundOn ? AppIcons.listen : AppIcons.mute,
                  tooltip: soundOn ? 'Mute' : 'Listen',
                  active: soundOn,
                  onPressed: () {
                    settings.soundOn = !settings.soundOn;
                    ScenovaScope.of(context).analytics.preferenceChanged(
                      setting: AnalyticsSetting.sound,
                      value: settings.soundOn,
                    );
                  },
                ),
              // The reader's rating of the clip: whether it showed the meaning
              // (`FEAT-010`). A clip that showed the wrong one is reported,
              // not rated (`FEAT-011`).
              ScenovaIconButton(
                icon: AppIcons.helpful,
                tooltip: 'This showed the meaning',
                active: feedback == ClipRating.helpful,
                onPressed: () =>
                    unawaited(_controller.markFeedback(ClipRating.helpful)),
              ),
              ScenovaIconButton(
                icon: AppIcons.notHelpful,
                tooltip: 'This did not show the meaning',
                active: feedback == ClipRating.notHelpful,
                onPressed: () =>
                    unawaited(_controller.markFeedback(ClipRating.notHelpful)),
              ),
              ScenovaIconButton(
                icon: AppIcons.more,
                tooltip: _actionsRevealed
                    ? 'Hide more actions'
                    : 'More actions',
                active: _actionsRevealed,
                onPressed: () =>
                    setState(() => _actionsRevealed = !_actionsRevealed),
              ),
            ],
          ),
          if (_actionsRevealed) ...<Widget>[
            SizedBox(height: tokens.spacing.sm),
            // Reporting names the clip the reader saw; it is the only way into
            // the report sheet, so it is revealed rather than dropped.
            ScenovaButton(
              label: 'Report',
              variant: ScenovaButtonVariant.secondary,
              icon: AppIcons.report,
              onPressed: () => unawaited(_openReportSheet()),
            ),
          ],
          SizedBox(height: tokens.spacing.sm),
          _feedbackNote(context),
        ],
        Wrap(
          spacing: tokens.spacing.sm,
          runSpacing: tokens.spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            // History is an app destination; an in-place view has nowhere to
            // open it, so the action is left out there.
            if (widget.presentation != ClipPresentation.inPlace)
              ScenovaButton(
                label: 'History',
                variant: ScenovaButtonVariant.ghost,
                onPressed: widget.onOpenHistory,
              ),
          ],
        ),
      ],
    );
  }

  /// Opens the Report sheet over the clip and tells the reader what came of it
  /// (`docs/Scenova/screens/05-report-sheet.md`; `FEAT-011`).
  Future<void> _openReportSheet() async {
    final services = ScenovaScope.of(context);
    final isPhrase = _controller.isPhrase;
    final outcome = await showReportSheet(
      context,
      word: _controller.word,
      // A phrase clip is kept only on the device, so its report has no shared
      // effect and the reader is told so (`FEAT-011`).
      privateToDevice: isPhrase,
      offline: !services.connectivity.isOnline,
      onSubmit: (reason, note) => _controller.submitReport(reason, note: note),
    );
    if (!mounted || outcome == null) return;
    _showMessage(_reportConfirmation(outcome, isPhrase: isPhrase));
  }

  /// What the reader is told once their report has been taken.
  String _reportConfirmation(ReportDelivery outcome, {required bool isPhrase}) {
    return switch (outcome) {
      ReportDelivery.sent =>
        isPhrase
            ? 'Thanks. This clip lives only on your device, so nothing else '
                  'changes.'
            : "Thanks — we'll check this clip before it's shown again.",
      ReportDelivery.queued =>
        "Saved. Your report will go out when you're back online.",
      ReportDelivery.duplicate => "You've already reported this clip. Thanks.",
      ReportDelivery.failed => "We couldn't send that just now.",
    };
  }

  /// What came of the reader's rating: the wait while it is sent, the
  /// confirmation, the note that it is held for the connection, or the failure
  /// with a retry (`FEAT-010`).
  ///
  /// A rating is never silently lost: when the service could not take it the
  /// reader is told, and the clip's own rating stays on the control.
  Widget _feedbackNote(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final delivery = _controller.feedbackDelivery;
    if (delivery == null) return const SizedBox.shrink();

    final (String message, bool retry) = switch (delivery) {
      FeedbackDelivery.sending => ('Saving…', false),
      FeedbackDelivery.recorded => ('Thanks — noted.', false),
      FeedbackDelivery.queued => (
        "Saved. It will go out when you're back online.",
        false,
      ),
      FeedbackDelivery.failed => ("We couldn't save that just now.", true),
    };

    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              message,
              style: styles.caption.copyWith(
                color: delivery == FeedbackDelivery.failed
                    ? colors.error.text
                    : colors.textSecondary,
              ),
            ),
          ),
          if (retry) ...<Widget>[
            SizedBox(width: tokens.spacing.sm),
            ScenovaButton(
              label: 'Try again',
              variant: ScenovaButtonVariant.ghost,
              icon: AppIcons.retry,
              onPressed: () => unawaited(_controller.retryFeedback()),
            ),
          ],
        ],
      ),
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
        _header(context),
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

  /// Whether the Paywall is live (`enable_paid_tier`). When the flag is off
  /// every reader reverts to Free and the Paywall is hidden
  /// (`docs/Scenova/release.md` → "Rollout Phases & Feature Flags").
  bool get _paywallEnabled =>
      ScenovaScope.of(context).featureFlags.paidTierEnabled;

  /// The action that opens the Paywall from the exhausted state. A reader who
  /// already holds Pro is offered the top-up rather than Pro again
  /// (`docs/Scenova/screens/04-paywall.md` → Edge Cases).
  Widget _plansAction(BuildContext context) {
    final alreadyPro =
        _controller.entitlement.isPro || _controller.entitlement.isTrial;
    return ScenovaButton(
      label: alreadyPro ? 'Add lookups' : 'See plans',
      variant: ScenovaButtonVariant.primary,
      onPressed: () => unawaited(_openPaywall()),
    );
  }

  /// Opens the Paywall sheet over the clip
  /// (`docs/Scenova/screens/04-paywall.md`).
  ///
  /// A purchase restores the allowance, so the lookup continues; a dismissal
  /// leaves the word and phrase in place.
  Future<void> _openPaywall() async {
    final outcome = await showPaywallSheet(
      context,
      entitlement: _controller.entitlement,
    );
    if (!mounted || outcome == null) return;
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
