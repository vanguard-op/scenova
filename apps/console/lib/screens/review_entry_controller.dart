import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/review_entry.dart';
import '../services/review_api.dart';

/// The entry's load state (`docs/Scenova/screens/10-review-entry.md` →
/// "States").
enum ReviewEntryStatus {
  /// The entry is loading: a skeleton card.
  loading,

  /// The entry loaded: the clip, the phrase, the evidence, and the actions.
  loaded,

  /// Another curator acted first: the entry has moved, so it is shown with its
  /// current state and no action is available (`C-016`, 409).
  moved,

  /// The entry or the action failed: the shared Error State with a retry.
  error,

  /// The operator is authenticated but may not review: access is refused.
  refused,
}

/// What came of a curator's action.
sealed class EntryActionOutcome {
  const EntryActionOutcome();
}

/// The action was recorded; the entry carries its new state.
final class EntryActionRecorded extends EntryActionOutcome {
  const EntryActionRecorded(this.result);

  final EntryActionResult result;
}

/// Another curator acted first; the entry has already moved (`C-016`, 409).
final class EntryActionMoved extends EntryActionOutcome {
  const EntryActionMoved();
}

/// The action was not recorded. The screen shows the failure and offers a
/// retry, unless it has already been reported to the console as a session or
/// role failure.
final class EntryActionFailed extends EntryActionOutcome {
  const EntryActionFailed(this.failure);

  final ReviewApiException failure;
}

/// Owns the Review Entry screen's data, its actions, and its states.
///
/// One controller drives the entry card, the evidence table, the actions, and
/// the phrase edit, so they never disagree about the entry's state. A session
/// that ends is reported to [onSessionExpired] so the console redirects to
/// sign-in; a refused role is kept as its own state, since retrying will not
/// change it.
class ReviewEntryController extends ChangeNotifier {
  ReviewEntryController({
    required this.api,
    required this.entryId,
    required this.onSessionExpired,
  });

  final ReviewApi api;

  /// The entry the queue opened.
  final String entryId;

  /// Called when the service reports no operator session, so the console
  /// redirects to sign-in (`C-015`, 401).
  final VoidCallback onSessionExpired;

  ReviewEntryStatus _status = ReviewEntryStatus.loading;
  ReviewEntryDetail? _detail;
  ReviewApiException? _failure;
  EntryAction? _submitting;
  ChosenClip? _submittingClip;
  ReviewApiException? _actionFailure;
  EntryAction? _failedAction;
  ChosenClip? _failedChosenClip;
  String? _failedPhrase;
  int _requestGeneration = 0;
  bool _disposed = false;

  ReviewEntryStatus get status => _status;
  ReviewEntryDetail? get detail => _detail;
  ReviewApiException? get failure => _failure;

  /// The action being recorded, or null when none is in flight.
  EntryAction? get submitting => _submitting;

  /// The clip the in-flight choice names, so only the button that was pressed
  /// shows its spinner, or null.
  ChosenClip? get submittingClip => _submittingClip;

  /// Whether an action is being recorded, so the screen disables the actions
  /// and shows a spinner (`docs/Scenova/screens/10-review-entry.md` →
  /// Submitting).
  bool get isSubmitting => _submitting != null;

  /// The last action failure the curator can retry, or null.
  ReviewApiException? get actionFailure => _actionFailure;

  /// Whether the entry's actions are available: a loaded entry that has not
  /// already moved.
  bool get canAct => _status == ReviewEntryStatus.loaded;

  /// The action the Error State is offering to retry, or null.
  EntryAction? get failedAction => _failedAction;

  /// The clip the failed action was choosing, so a retry re-sends the same
  /// choice, or null.
  ChosenClip? get failedChosenClip => _failedChosenClip;

  /// Loads the entry and its evidence.
  Future<void> load() async {
    final generation = ++_requestGeneration;
    // A first load, or a retry after a failure, shows the skeleton card; a
    // reload of an entry already on screen keeps it rather than flashing the
    // placeholder.
    if (_detail == null || _status == ReviewEntryStatus.error) {
      _status = ReviewEntryStatus.loading;
    }
    _failure = null;
    _notify();

    try {
      final detail = await api.entry(entryId);
      if (generation != _requestGeneration || _disposed) return;
      _detail = detail;
      _status = ReviewEntryStatus.loaded;
      _failure = null;
    } on ReviewApiException catch (error) {
      if (generation != _requestGeneration || _disposed) return;
      if (error.isUnauthenticated) {
        // The session ended while the entry was open; the console redirects to
        // sign-in rather than showing a retry.
        onSessionExpired();
        return;
      }
      _failure = error;
      _status = error.isForbidden
          ? ReviewEntryStatus.refused
          : ReviewEntryStatus.error;
    } finally {
      if (generation == _requestGeneration && !_disposed) _notify();
    }
  }

  /// Records [action] against the entry.
  ///
  /// A `choose` names the clip that serves every reader from now on
  /// ([chosenClip]); a phrase edit carries the new [phrase]. The request carries
  /// the state the curator saw, so the service refuses an action on an entry
  /// another curator has moved (`C-016` 409); that refusal lands as
  /// [ReviewEntryStatus.moved] and the entry is re-read so its current state is
  /// shown.
  Future<EntryActionOutcome> act(
    EntryAction action, {
    ChosenClip? chosenClip,
    String? phrase,
  }) async {
    final detail = _detail;
    if (detail == null || _submitting != null) {
      return const EntryActionFailed(
        ReviewApiException(0, 'The entry is not ready to be acted on.'),
      );
    }
    if (action == EntryAction.choose && chosenClip == null) {
      // The contract refuses a `choose` without a clip (`C-016` 400); the
      // screen always names one, so this is a guard rather than a path.
      return const EntryActionFailed(
        ReviewApiException(400, 'Choose which clip serves the entry.'),
      );
    }

    _submitting = action;
    _submittingClip = action == EntryAction.choose ? chosenClip : null;
    _actionFailure = null;
    _failedAction = null;
    _failedChosenClip = null;
    _failedPhrase = null;
    _notify();

    try {
      final result = await api.act(
        entryId,
        EntryActionRequest(
          action: action,
          expectedState: detail.state,
          chosenClip: action == EntryAction.choose ? chosenClip : null,
          phrase: action == EntryAction.editPhrase ? phrase : null,
        ),
      );
      if (_disposed) return EntryActionRecorded(result);
      _applyResult(action, result, chosenClip: chosenClip, phrase: phrase);
      _submitting = null;
      _submittingClip = null;
      _notify();
      return EntryActionRecorded(result);
    } on ReviewApiException catch (error) {
      if (_disposed) return EntryActionFailed(error);
      _submitting = null;
      _submittingClip = null;
      if (error.isUnauthenticated) {
        _notify();
        onSessionExpired();
        return EntryActionFailed(error);
      }
      if (error.isForbidden) {
        _failure = error;
        _status = ReviewEntryStatus.refused;
        _notify();
        return EntryActionFailed(error);
      }
      if (error.isConflict) {
        _status = ReviewEntryStatus.moved;
        _notify();
        // Re-read the entry so the moved note can show the state it moved to.
        await _refreshMovedEntry();
        return const EntryActionMoved();
      }
      if (error.isNotFound) {
        _failure = error;
        _status = ReviewEntryStatus.error;
        _notify();
        return EntryActionFailed(error);
      }
      // A failure the curator can retry in place: the entry stays on screen
      // and the actions panel shows the shared Error State.
      _actionFailure = error;
      _failedAction = action;
      _failedChosenClip = chosenClip;
      _failedPhrase = phrase;
      _notify();
      return EntryActionFailed(error);
    }
  }

  /// Re-attempts the action that failed, for the Error State's retry.
  Future<EntryActionOutcome> retryFailedAction() {
    final action = _failedAction;
    if (action == null) {
      return Future<EntryActionOutcome>.value(
        const EntryActionFailed(
          ReviewApiException(0, 'There is nothing to retry.'),
        ),
      );
    }
    return act(action, chosenClip: _failedChosenClip, phrase: _failedPhrase);
  }

  /// Dismisses the action failure without retrying.
  void clearActionFailure() {
    if (_actionFailure == null) return;
    _actionFailure = null;
    _failedAction = null;
    _failedChosenClip = null;
    _failedPhrase = null;
    _notify();
  }

  /// Moves the entry onto the result of a recorded action.
  ///
  /// A `choose` of the candidate makes it the clip the library serves and spends
  /// the candidate; a `retire` or an `edit_phrase` also clears it, since the
  /// queue item is resolved or the entry is regenerating.
  void _applyResult(
    EntryAction action,
    EntryActionResult result, {
    ChosenClip? chosenClip,
    String? phrase,
  }) {
    final detail = _detail;
    if (detail == null) return;
    final entry = detail.entry;
    final editedPhrase = action == EntryAction.editPhrase
        ? (phrase ?? entry.glossPhrase).trim()
        : entry.glossPhrase;
    final chosenCandidate =
        action == EntryAction.choose && chosenClip == ChosenClip.candidate;
    _detail = ReviewEntryDetail(
      entry: ReviewEntry(
        entryId: entry.entryId,
        lemma: entry.lemma,
        senseLabel: entry.senseLabel,
        glossPhrase: editedPhrase,
        status: result.status,
        clip: chosenCandidate ? (detail.candidate ?? entry.clip) : entry.clip,
      ),
      candidate: null,
      reports: detail.reports,
      feedback: detail.feedback,
      state: result.state,
    );
  }

  /// Re-reads an entry another curator moved, so the note can show its current
  /// state. A failed re-read leaves the last-known entry in place.
  Future<void> _refreshMovedEntry() async {
    try {
      final detail = await api.entry(entryId);
      if (_disposed) return;
      _detail = detail;
      _notify();
    } on ReviewApiException catch (error) {
      if (_disposed) return;
      if (error.isUnauthenticated) {
        onSessionExpired();
        return;
      }
      // The entry was superseded by a regeneration, or the service is
      // unreachable; the moved note stands with the state the console has.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
