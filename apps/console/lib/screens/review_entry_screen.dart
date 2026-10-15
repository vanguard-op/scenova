import 'dart:async';

import 'package:flutter/material.dart';

import '../models/phrase_rubric.dart';
import '../models/review_entry.dart';
import '../models/review_queue.dart';
import '../services/console_services.dart';
import '../services/review_api.dart';
import '../theme/colors.dart';
import '../theme/layout.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/app_icons.dart';
import '../widgets/clip_player.dart';
import '../widgets/entry_evidence_table.dart';
import '../widgets/scenova_button.dart';
import '../widgets/skeleton.dart';
import '../widgets/states.dart';
import '../widgets/status_badge.dart';
import 'review_entry_controller.dart';

/// Screen 10: Review Entry (`docs/Scenova/screens/10-review-entry.md`).
///
/// The queue drills down into one entry. The curator judges the clip with its
/// generation phrase against the evidence — the reports and the negative
/// feedback — and clears, holds, retires, or replaces the entry, or edits the
/// phrase it is generated from.
///
/// The controller is created here and owns the entry's data, its actions, and
/// its states. A caller may pass one in (a test, or a host that already holds
/// it), in which case loading it is the caller's to start.
class ReviewEntryScreen extends StatefulWidget {
  const ReviewEntryScreen({
    super.key,
    required this.entryId,
    required this.onBack,
    this.controller,
  });

  /// The entry the queue opened (`C-015` path).
  final String entryId;

  /// Returns to the queue.
  final VoidCallback onBack;

  /// An externally owned controller, or null to create one from the console's
  /// services.
  final ReviewEntryController? controller;

  @override
  State<ReviewEntryScreen> createState() => _ReviewEntryScreenState();
}

class _ReviewEntryScreenState extends State<ReviewEntryScreen> {
  ReviewEntryController? _controller;
  bool _ownsController = false;
  VoidCallback _signOut = () {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = ConsoleScope.maybeOf(context);
    if (scope != null) {
      _signOut = () => unawaited(scope.auth.signOut());
    }
    if (_controller != null) return;
    final provided = widget.controller;
    if (provided != null) {
      _controller = provided;
      return;
    }
    assert(scope != null, 'The entry screen needs a ConsoleScope.');
    final controller = ReviewEntryController(
      api: scope!.reviewApi,
      entryId: widget.entryId,
      onSessionExpired: _signOut,
    );
    _controller = controller;
    _ownsController = true;
    unawaited(controller.load());
  }

  @override
  void dispose() {
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context, controller),
    );
  }

  Widget _body(BuildContext context, ReviewEntryController controller) {
    switch (controller.status) {
      case ReviewEntryStatus.loading:
        return const _EntrySkeleton();
      case ReviewEntryStatus.refused:
        return _CentredState(
          child: EmptyState(
            icon: AppIcons.refused,
            headline: 'Access refused',
            body:
                'This account does not have the curator role. '
                'Ask an administrator to grant it, then sign in again.',
            actionLabel: 'Sign out',
            onAction: _signOut,
          ),
        );
      case ReviewEntryStatus.error:
        return _CentredState(child: _errorState(controller));
      case ReviewEntryStatus.loaded:
      case ReviewEntryStatus.moved:
        return _loaded(context, controller);
    }
  }

  /// The shared Error State, worded for what the curator can do about it.
  ///
  /// An entry with nothing queued is not a failure to retry — it has been
  /// resolved or superseded — so the state offers the way back instead.
  Widget _errorState(ReviewEntryController controller) {
    final failure = controller.failure;
    if (failure != null && failure.isNotFound) {
      return ErrorState(
        headline: 'This entry is no longer waiting for review',
        body:
            'It has already been resolved, or a regeneration replaced it. '
            'The queue lists what is still open.',
        retryLabel: 'Back to the queue',
        onRetry: widget.onBack,
      );
    }
    return ErrorState(
      headline: 'The entry could not be loaded',
      body: _failureBody(failure),
      onRetry: controller.load,
    );
  }

  static String _failureBody(ReviewApiException? failure) {
    if (failure == null) return 'Something went wrong. Try again.';
    if (failure.isOffline) {
      return 'The console could not reach the review service. '
          'Check your connection and try again.';
    }
    return failure.message;
  }

  Widget _loaded(BuildContext context, ReviewEntryController controller) {
    final detail = controller.detail;
    if (detail == null) return const _EntrySkeleton();
    final tokens = ScenovaTokens.of(context);
    final moved = controller.status == ReviewEntryStatus.moved;

    return SingleChildScrollView(
      padding: EdgeInsets.all(tokens.spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: ScenovaButton(
              label: 'Back to the queue',
              variant: ScenovaButtonVariant.ghost,
              icon: AppIcons.previous,
              onPressed: widget.onBack,
            ),
          ),
          SizedBox(height: tokens.spacing.md),
          _EntryHeading(detail: detail),
          SizedBox(height: tokens.spacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              final card = _EntryCard(detail: detail);
              final evidence = EntryEvidenceTable(detail: detail);
              if (constraints.maxWidth <
                  ConsoleLayout.entrySideBySideMinWidth) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    card,
                    SizedBox(height: tokens.spacing.lg),
                    evidence,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: ConsoleLayout.entryCardFlex, child: card),
                  SizedBox(width: tokens.spacing.lg),
                  Expanded(
                    flex: ConsoleLayout.entryEvidenceFlex,
                    child: evidence,
                  ),
                ],
              );
            },
          ),
          SizedBox(height: tokens.spacing.xl),
          if (moved)
            _MovedNote(state: detail.state)
          else
            _ActionsPanel(
              detail: detail,
              submitting: controller.submitting,
              failure: controller.actionFailure,
              onAction: _runAction,
              onRetry: _retryAction,
              onDismiss: controller.clearActionFailure,
              onPhrase: (phrase) =>
                  _runAction(EntryAction.editPhrase, phrase: phrase),
            ),
        ],
      ),
    );
  }

  /// Records an action. A destructive one is confirmed first, in a modal that
  /// blocks until it is resolved (`docs/Scenova/screens/10-review-entry.md` →
  /// Overlays).
  Future<void> _runAction(EntryAction action, {String? phrase}) async {
    final controller = _controller;
    if (controller == null) return;

    if (action.isDestructive) {
      final outcome = await showDialog<EntryActionOutcome>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _ConfirmActionDialog(
          action: action,
          lemma: controller.detail?.entry.lemma ?? '',
          onConfirm: () => controller.act(action),
        ),
      );
      if (!mounted || outcome is! EntryActionRecorded) return;
      _confirmAction(action);
      return;
    }

    final outcome = await controller.act(action, phrase: phrase);
    if (!mounted || outcome is! EntryActionRecorded) return;
    _confirmAction(action);
  }

  /// Re-attempts the action the Error State is offering to retry.
  Future<void> _retryAction() async {
    final controller = _controller;
    if (controller == null) return;
    final action = controller.failedAction;
    final outcome = await controller.retryFailedAction();
    if (!mounted || action == null || outcome is! EntryActionRecorded) return;
    _confirmAction(action);
  }

  /// Confirms a recorded action and, for one that resolves the queue item,
  /// returns to the queue.
  void _confirmAction(EntryAction action) {
    final message = switch (action) {
      EntryAction.clear => 'Cleared. The clip is serving readers again.',
      EntryAction.hold =>
        'Held. The clip is withheld from new readers until it is cleared '
            'or replaced.',
      EntryAction.retire =>
        'Retired. The clip has stopped serving; the next lookup of this word '
            'generates a replacement.',
      EntryAction.replace =>
        'Replaced. The clip has stopped serving and a new one is generating.',
      EntryAction.editPhrase =>
        'Phrase saved. The entry is regenerating from it.',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    if (action.returnsToQueue) widget.onBack();
  }
}

/// The entry's word, its sense, and its two states: where it sits in the queue
/// and whether it is in front of readers.
class _EntryHeading extends StatelessWidget {
  const _EntryHeading({required this.detail});

  final ReviewEntryDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final entry = detail.entry;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(entry.lemma, style: styles.h1.copyWith(color: colors.textPrimary)),
        SizedBox(height: tokens.spacing.xs),
        Text(
          'Sense ${entry.senseLabel}',
          style: styles.bodyLarge.copyWith(color: colors.textSecondary),
        ),
        SizedBox(height: tokens.spacing.md),
        Wrap(
          spacing: tokens.spacing.sm,
          runSpacing: tokens.spacing.sm,
          children: <Widget>[
            ReviewStatusBadge(state: detail.state),
            EntryStatusBadge(status: entry.status),
          ],
        ),
      ],
    );
  }
}

/// The entry card: the clip with the word as its caption, and the generation
/// phrase the clip is made from
/// (`docs/Scenova/screens/10-review-entry.md` → Layout).
class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.detail});

  final ReviewEntryDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final entry = detail.entry;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
      ),
      padding: EdgeInsets.all(tokens.spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ClipPlayer(caption: entry.lemma, clip: entry.clip),
          SizedBox(height: tokens.spacing.md),
          Text(
            '${entry.lemma} · sense ${entry.senseLabel}',
            style: styles.bodySmall.copyWith(color: colors.textSecondary),
          ),
          SizedBox(height: tokens.spacing.lg),
          Text(
            'Generation phrase',
            style: styles.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: tokens.spacing.xs),
          Text(
            entry.glossPhrase.isEmpty ? '—' : entry.glossPhrase,
            style: styles.bodyLarge.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// The note that another curator acted first
/// (`docs/Scenova/screens/10-review-entry.md` → Already moved).
///
/// It stands where the actions would be, so the entry cannot be acted on again,
/// and names the state the entry moved to.
class _MovedNote extends StatelessWidget {
  const _MovedNote({required this.state});

  final ReviewState state;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.warning.tint,
        border: Border.all(color: colors.warning.border),
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
      ),
      padding: EdgeInsets.all(tokens.spacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppIconView(
            icon: AppIcons.warning,
            size: tokens.sizing.iconMd,
            color: colors.warning.text,
          ),
          SizedBox(width: tokens.spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'This entry has already moved',
                  style: styles.body.copyWith(
                    color: colors.warning.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: tokens.spacing.xs),
                Text(
                  'Another curator acted on it first, so no action is '
                  'available here. Its current state is ${state.label}.',
                  style: styles.bodySmall.copyWith(color: colors.warning.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The decisions a curator can record, and the phrase edit beneath them
/// (`docs/Scenova/screens/10-review-entry.md` → Components).
class _ActionsPanel extends StatelessWidget {
  const _ActionsPanel({
    required this.detail,
    required this.submitting,
    required this.failure,
    required this.onAction,
    required this.onRetry,
    required this.onDismiss,
    required this.onPhrase,
  });

  final ReviewEntryDetail detail;
  final EntryAction? submitting;
  final ReviewApiException? failure;
  final ValueChanged<EntryAction> onAction;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;
  final ValueChanged<String> onPhrase;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final busy = submitting != null;

    // A failed action leaves the entry on screen and shows the shared Error
    // State where the actions are
    // (`docs/Scenova/screens/10-review-entry.md` → Error). An outage is worth
    // another attempt; a request the service refused is not, so the curator is
    // given the actions back instead of a retry that would fail the same way.
    final failure = this.failure;
    if (failure != null) {
      final retryable = failure.isOffline || failure.isRetryable;
      return ErrorState(
        headline: 'The action could not be recorded',
        body: failure.isOffline
            ? 'The console could not reach the review service. '
                  'Check your connection and try again.'
            : failure.message,
        retryLabel: retryable ? 'Try again' : 'Dismiss',
        onRetry: retryable ? onRetry : onDismiss,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Decision', style: styles.h3.copyWith(color: colors.textPrimary)),
        SizedBox(height: tokens.spacing.xs),
        Text(
          'Clear the entry to serve it again, hold it from new readers, or '
          'retire or replace its clip.',
          style: styles.bodySmall.copyWith(color: colors.textSecondary),
        ),
        SizedBox(height: tokens.spacing.md),
        Wrap(
          spacing: tokens.spacing.md,
          runSpacing: tokens.spacing.md,
          children: <Widget>[
            ScenovaButton(
              label: EntryAction.clear.label,
              icon: AppIcons.check,
              isSubmitting: submitting == EntryAction.clear,
              onPressed: busy ? null : () => onAction(EntryAction.clear),
            ),
            ScenovaButton(
              label: EntryAction.hold.label,
              variant: ScenovaButtonVariant.outline,
              icon: AppIcons.pause,
              isSubmitting: submitting == EntryAction.hold,
              onPressed: busy ? null : () => onAction(EntryAction.hold),
            ),
            ScenovaButton(
              label: EntryAction.retire.label,
              variant: ScenovaButtonVariant.destructive,
              icon: AppIcons.remove,
              isSubmitting: submitting == EntryAction.retire,
              onPressed: busy ? null : () => onAction(EntryAction.retire),
            ),
            ScenovaButton(
              label: EntryAction.replace.label,
              variant: ScenovaButtonVariant.destructive,
              icon: AppIcons.replay,
              isSubmitting: submitting == EntryAction.replace,
              onPressed: busy ? null : () => onAction(EntryAction.replace),
            ),
          ],
        ),
        SizedBox(height: tokens.spacing.xl),
        Text(
          'Edit the generation phrase',
          style: styles.h3.copyWith(color: colors.textPrimary),
        ),
        SizedBox(height: tokens.spacing.xs),
        Text(
          'Rewrite the phrase the clip is generated from. The entry '
          'regenerates from the new phrase and stays under review.',
          style: styles.bodySmall.copyWith(color: colors.textSecondary),
        ),
        SizedBox(height: tokens.spacing.md),
        _PhraseEditField(
          phrase: detail.entry.glossPhrase,
          enabled: !busy,
          submitting: submitting == EntryAction.editPhrase,
          onSubmit: onPhrase,
        ),
      ],
    );
  }
}

/// The phrase edit: a field seeded with the entry's generation phrase and a
/// regenerate action.
///
/// It holds the phrase to the rubric before it sends anything, so a phrase that
/// cannot pass is refused where the curator can see why and the entry's stored
/// phrase is left unchanged
/// (`docs/Scenova/screens/10-review-entry.md` → Edge Cases).
class _PhraseEditField extends StatefulWidget {
  const _PhraseEditField({
    required this.phrase,
    required this.enabled,
    required this.submitting,
    required this.onSubmit,
  });

  final String phrase;
  final bool enabled;
  final bool submitting;
  final ValueChanged<String> onSubmit;

  @override
  State<_PhraseEditField> createState() => _PhraseEditFieldState();
}

class _PhraseEditFieldState extends State<_PhraseEditField> {
  late final TextEditingController _field = TextEditingController(
    text: widget.phrase,
  );
  String? _error;

  @override
  void didUpdateWidget(_PhraseEditField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A phrase changed elsewhere — a recorded edit, a reload — lands in the
    // field, so it never shows a phrase the entry no longer carries.
    if (widget.phrase != oldWidget.phrase) {
      _field.text = widget.phrase;
      _error = null;
    }
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _field.text;
    final error = phraseRubricError(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _error = null);
    widget.onSubmit(value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);

    return Wrap(
      spacing: tokens.spacing.md,
      runSpacing: tokens.spacing.md,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: ConsoleLayout.phraseFieldWidth,
          child: TextField(
            controller: _field,
            enabled: widget.enabled,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Generation phrase',
              hintText: 'Up to seven words',
              helperText:
                  'Seven words or fewer, common words, one clear '
                  'meaning.',
              errorText: _error,
            ),
          ),
        ),
        ScenovaButton(
          label: EntryAction.editPhrase.label,
          variant: ScenovaButtonVariant.secondary,
          icon: AppIcons.replay,
          isSubmitting: widget.submitting,
          onPressed: widget.enabled ? _submit : null,
        ),
      ],
    );
  }
}

/// The confirmation a destructive action opens
/// (`docs/Scenova/screens/10-review-entry.md` → Overlays).
///
/// It blocks until it is resolved, states the effect on readers who rely on the
/// entry before the action is recorded, and carries its own submitting and
/// error states.
class _ConfirmActionDialog extends StatefulWidget {
  const _ConfirmActionDialog({
    required this.action,
    required this.lemma,
    required this.onConfirm,
  });

  final EntryAction action;
  final String lemma;
  final Future<EntryActionOutcome> Function() onConfirm;

  @override
  State<_ConfirmActionDialog> createState() => _ConfirmActionDialogState();
}

class _ConfirmActionDialogState extends State<_ConfirmActionDialog> {
  bool _submitting = false;
  String? _error;

  Future<void> _confirm() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final outcome = await widget.onConfirm();
    if (!mounted) return;

    // A failure the curator can retry stays in the modal. A session that ended
    // or a role that was refused is the console's to answer, so the modal
    // closes and the screen behind it carries the outcome.
    if (outcome is EntryActionFailed) {
      final failure = outcome.failure;
      if (failure.isUnauthenticated ||
          failure.isForbidden ||
          failure.isNotFound) {
        Navigator.of(context).pop(outcome);
        return;
      }
      setState(() {
        _submitting = false;
        _error = failure.message;
      });
      return;
    }
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final retire = widget.action == EntryAction.retire;
    final verb = retire ? 'Retire' : 'Replace';

    return AlertDialog(
      title: Text('$verb “${widget.lemma}”?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ConsoleLayout.dialogMaxWidth,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _effect(retire),
              style: styles.body.copyWith(color: colors.textSecondary),
            ),
            if (_error != null)
              Padding(
                padding: EdgeInsets.only(top: tokens.spacing.md),
                child: Container(
                  padding: EdgeInsets.all(tokens.spacing.md),
                  decoration: BoxDecoration(
                    color: colors.error.tint,
                    border: Border.all(color: colors.error.border),
                    borderRadius: BorderRadius.circular(ScenovaRadius.md),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      AppIconView(
                        icon: AppIcons.warning,
                        size: tokens.sizing.iconSm,
                        color: colors.error.text,
                      ),
                      SizedBox(width: tokens.spacing.sm),
                      Expanded(
                        child: Text(
                          _error!,
                          style: styles.bodySmall.copyWith(
                            color: colors.error.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        ScenovaButton(
          label: 'Cancel',
          variant: ScenovaButtonVariant.ghost,
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        ScenovaButton(
          label: verb,
          variant: ScenovaButtonVariant.destructive,
          icon: retire ? AppIcons.remove : AppIcons.replay,
          isSubmitting: _submitting,
          onPressed: _submitting ? null : _confirm,
        ),
      ],
    );
  }

  /// The effect of the action, stated before it is recorded, so a curator knows
  /// what happens to the readers who rely on the entry.
  String _effect(bool retire) {
    if (retire) {
      return 'Readers stop seeing this clip. The next lookup of '
          '“${widget.lemma}” generates a replacement, and readers who already '
          'have the clip keep it.';
    }
    return 'This clip stops serving and a new one is generated from a fresh '
        'phrase. Readers who already have the clip keep it.';
  }
}

/// The entry's loading shape: a skeleton card and a skeleton evidence table, so
/// the layout holds while the entry is in flight
/// (`docs/Scenova/screens/10-review-entry.md` → Loading).
class _EntrySkeleton extends StatelessWidget {
  const _EntrySkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    Widget card({required Widget child}) {
      return Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        ),
        padding: EdgeInsets.all(tokens.spacing.lg),
        child: child,
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(tokens.spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SkeletonLine(widthFactor: 0.18, height: 28),
          SizedBox(height: tokens.spacing.sm),
          const SkeletonLine(widthFactor: 0.1, height: 17),
          SizedBox(height: tokens.spacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: ConsoleLayout.entryCardFlex,
                child: card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const AspectRatio(
                        aspectRatio: ConsoleLayout.clipAspectRatio,
                        child: SkeletonBlock(),
                      ),
                      SizedBox(height: tokens.spacing.md),
                      const SkeletonLine(widthFactor: 0.3),
                      SizedBox(height: tokens.spacing.lg),
                      const SkeletonLine(widthFactor: 0.4, height: 12),
                      SizedBox(height: tokens.spacing.sm),
                      const SkeletonLine(widthFactor: 0.7, height: 17),
                    ],
                  ),
                ),
              ),
              SizedBox(width: tokens.spacing.lg),
              Expanded(
                flex: ConsoleLayout.entryEvidenceFlex,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SkeletonLine(widthFactor: 0.35, height: 18),
                    SizedBox(height: tokens.spacing.md),
                    card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          const SkeletonLine(widthFactor: 0.4),
                          SizedBox(height: tokens.spacing.md),
                          const SkeletonLine(widthFactor: 0.9),
                          SizedBox(height: tokens.spacing.md),
                          const SkeletonLine(widthFactor: 0.75),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Gives a centred state breathing room inside the scrolling body.
class _CentredState extends StatelessWidget {
  const _CentredState({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.xxl),
      child: child,
    );
  }
}
