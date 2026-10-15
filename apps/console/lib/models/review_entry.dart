import 'package:flutter/foundation.dart';
import 'package:scenova_design/scenova_design.dart';

import 'review_queue.dart';

/// The models behind the Review Entry screen, as frozen in `C-015` and `C-016`.
///
/// `C-015` shows one queued entry with the clip, the word and sense, the
/// generation phrase, the reports and negative feedback against it, and the
/// queue item's state. `C-016` records the curator's action and returns the
/// entry's new library status and the item's new state. The wire shapes are the
/// contract's; nothing here renames a field.

/// Whether a library entry is serving, withheld, or stopped (`C-015`
/// `entry.status`).
///
/// It is the library's own status, distinct from the queue item's review state:
/// a curator decides an action knowing whether the clip is currently in front
/// of readers.
enum EntryStatus {
  active('active', 'Serving'),
  held('held', 'Held'),
  retired('retired', 'Retired');

  const EntryStatus(this.wireValue, this.label);

  final String wireValue;

  /// The label a curator reads.
  final String label;

  static EntryStatus? fromWire(String? value) {
    for (final status in EntryStatus.values) {
      if (status.wireValue == value) return status;
    }
    return null;
  }
}

/// What a curator did to an entry (`C-016` `action`).
enum EntryAction {
  clear('clear', 'Clear'),
  hold('hold', 'Hold'),
  retire('retire', 'Retire'),
  replace('replace', 'Replace'),
  editPhrase('edit_phrase', 'Regenerate');

  const EntryAction(this.wireValue, this.label);

  /// The value on the wire.
  final String wireValue;

  /// The label a curator reads on the action.
  final String label;

  /// Whether the action resolves the queue item and returns the curator to the
  /// queue. A phrase edit regenerates the entry and leaves it under review, so
  /// the curator stays on the entry (`C-016` 200 `state`).
  bool get returnsToQueue => this != EntryAction.editPhrase;

  /// Whether the action stops the clip serving, so it is confirmed before it is
  /// recorded (`docs/Scenova/screens/10-review-entry.md` → Overlays).
  bool get isDestructive =>
      this == EntryAction.retire || this == EntryAction.replace;
}

/// A reader's rating of a clip (`C-012`), as the entry's evidence lists it.
///
/// `C-015` returns only the negative ratings — `not_helpful` and `wrong` — so
/// the console reads them as the case against the entry.
enum FeedbackRating {
  helpful('helpful', 'Helpful'),
  notHelpful('not_helpful', 'Not helpful'),
  wrong('wrong', 'Wrong');

  const FeedbackRating(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static FeedbackRating? fromWire(String? value) {
    for (final rating in FeedbackRating.values) {
      if (rating.wireValue == value) return rating;
    }
    return null;
  }
}

/// The clip behind a queued entry (`C-015` `entry.clip`).
///
/// It implements the design system's [ClipSource], so the shared Clip Player
/// takes it as it is.
@immutable
class ReviewClip implements ClipSource {
  const ReviewClip({
    required this.url,
    required this.durationSeconds,
    required this.resolution,
    required this.hasAudio,
  });

  @override
  final String url;
  @override
  final double durationSeconds;
  @override
  final String resolution;
  @override
  final bool hasAudio;

  /// Whether the source is one a video player can stream. A scripted or empty
  /// source is not, so the player holds a still frame instead of asking the
  /// platform to open something it cannot play.
  bool get isPlayable => isPlayableClipUrl(url);

  static ReviewClip fromJson(Map<String, dynamic> json) {
    return ReviewClip(
      url: json['url'] as String,
      durationSeconds: (json['durationSeconds'] as num).toDouble(),
      resolution: json['resolution'] as String,
      hasAudio: json['hasAudio'] as bool,
    );
  }
}

/// The library entry a curator reviews (`C-015` `entry`).
@immutable
class ReviewEntry {
  const ReviewEntry({
    required this.entryId,
    required this.lemma,
    required this.senseLabel,
    required this.glossPhrase,
    required this.status,
    required this.clip,
  });

  final String entryId;

  /// The entry's word.
  final String lemma;

  /// The entry's sense, as a plain human label.
  final String senseLabel;

  /// The phrase the clip is generated from.
  final String glossPhrase;

  final EntryStatus status;
  final ReviewClip clip;

  static ReviewEntry fromJson(Map<String, dynamic> json) {
    return ReviewEntry(
      entryId: json['entryId'] as String,
      lemma: json['lemma'] as String,
      senseLabel: json['senseLabel'] as String,
      glossPhrase: json['glossPhrase'] as String,
      status:
          EntryStatus.fromWire(json['status'] as String?) ?? EntryStatus.active,
      clip: ReviewClip.fromJson(json['clip'] as Map<String, dynamic>),
    );
  }
}

/// One reader report against a queued entry (`C-015` `reports`).
@immutable
class EntryReport {
  const EntryReport({
    required this.reportId,
    required this.reason,
    required this.note,
    required this.createdAt,
  });

  final String reportId;
  final String reason;

  /// The reader's note, when they left one.
  final String? note;

  final DateTime createdAt;

  /// The reason as a curator reads it. A reader's reason resolves to its own
  /// label; anything else falls back to the service's own text, so an
  /// unrecognised reason is shown rather than dropped.
  String get reasonLabel => ReviewReason.fromWire(reason)?.label ?? reason;

  static EntryReport fromJson(Map<String, dynamic> json) {
    return EntryReport(
      reportId: json['reportId'] as String,
      reason: json['reason'] as String,
      note: json['note'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    );
  }
}

/// One negative rating against a queued entry (`C-015` `feedback`).
@immutable
class EntryFeedback {
  const EntryFeedback({required this.rating, required this.createdAt});

  final FeedbackRating rating;
  final DateTime createdAt;

  static EntryFeedback fromJson(Map<String, dynamic> json) {
    return EntryFeedback(
      rating:
          FeedbackRating.fromWire(json['rating'] as String?) ??
          FeedbackRating.notHelpful,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    );
  }
}

/// The `C-015` 200 response: the entry, its evidence, and its review state.
@immutable
class ReviewEntryDetail {
  const ReviewEntryDetail({
    required this.entry,
    required this.reports,
    required this.feedback,
    required this.state,
  });

  final ReviewEntry entry;

  /// The reports against the entry, newest first.
  final List<EntryReport> reports;

  /// The negative ratings against the entry, newest first.
  final List<EntryFeedback> feedback;

  final ReviewState state;

  /// Whether the evidence the decision rests on is empty.
  bool get hasEvidence => reports.isNotEmpty || feedback.isNotEmpty;

  static ReviewEntryDetail fromJson(Map<String, dynamic> json) {
    final reports = (json['reports'] as List<dynamic>)
        .map((report) => EntryReport.fromJson(report as Map<String, dynamic>))
        .toList(growable: false);
    final feedback = (json['feedback'] as List<dynamic>)
        .map((rating) => EntryFeedback.fromJson(rating as Map<String, dynamic>))
        .toList(growable: false);
    return ReviewEntryDetail(
      entry: ReviewEntry.fromJson(json['entry'] as Map<String, dynamic>),
      reports: reports,
      feedback: feedback,
      state:
          ReviewState.fromWire(json['state'] as String?) ?? ReviewState.queued,
    );
  }
}

/// The `C-016` request body: the action, the new phrase for an edit, the
/// curator's note, and the state the curator acted on.
///
/// `expectedState` guards against two curators acting at once: the service
/// compares it with the item's current state and refuses an action on an entry
/// that has moved (`C-016` 409).
@immutable
class EntryActionRequest {
  const EntryActionRequest({
    required this.action,
    required this.expectedState,
    this.phrase,
    this.notes,
  });

  final EntryAction action;

  /// The state the curator saw the entry in.
  final ReviewState expectedState;

  /// The new generation phrase, for an `edit_phrase` only.
  final String? phrase;

  /// The curator's note, at most 500 characters (`C-016`).
  final String? notes;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'action': action.wireValue,
      'phrase': phrase,
      'notes': notes,
      'expectedState': expectedState.wireValue,
    };
  }
}

/// The `C-016` 200 response: the recorded action and the entry's new state.
@immutable
class EntryActionResult {
  const EntryActionResult({
    required this.actionId,
    required this.entryId,
    required this.status,
    required this.state,
  });

  final String actionId;
  final String entryId;

  /// The entry's new library status.
  final EntryStatus status;

  /// The queue item's new state.
  final ReviewState state;

  static EntryActionResult fromJson(Map<String, dynamic> json) {
    return EntryActionResult(
      actionId: json['actionId'] as String,
      entryId: json['entryId'] as String,
      status:
          EntryStatus.fromWire(json['status'] as String?) ?? EntryStatus.active,
      state:
          ReviewState.fromWire(json['state'] as String?) ?? ReviewState.queued,
    );
  }
}
