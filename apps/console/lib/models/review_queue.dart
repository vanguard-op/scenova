import 'package:flutter/foundation.dart';

/// The models behind the review queue, as frozen in `C-014`.
///
/// `C-014` lists one item per entry awaiting review — however many reports it
/// holds — newest first, with the queue's open-item count and its paging. The
/// wire shapes are the contract's; nothing here renames a field.

/// The state of a queue item (`C-014` `state`).
enum ReviewState {
  queued('queued', 'Queued'),
  reviewed('reviewed', 'Reviewed'),
  actioned('actioned', 'Actioned');

  const ReviewState(this.wireValue, this.label);

  /// The value on the wire and in the filter query.
  final String wireValue;

  /// The label a curator reads.
  final String label;

  static ReviewState? fromWire(String? value) {
    for (final state in ReviewState.values) {
      if (state.wireValue == value) return state;
    }
    return null;
  }
}

/// The reasons a reader can report a clip with (`C-013` `reason`), which are
/// also the queue's reason filter (`C-014` `reason`).
///
/// An entry queued by repeated negative feedback instead of a report carries
/// the service's own `feedback_threshold` reason, which is not a reader's to
/// choose and so is not offered as a filter; [QueueItem.reasonLabel] renders
/// it.
enum ReviewReason {
  wrongMeaning('wrong_meaning', 'Wrong meaning'),
  offensive('offensive', 'Offensive'),
  lowQuality('low_quality', 'Low quality'),
  other('other', 'Other');

  const ReviewReason(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static ReviewReason? fromWire(String? value) {
    for (final reason in ReviewReason.values) {
      if (reason.wireValue == value) return reason;
    }
    return null;
  }
}

/// The reason the review service records for an entry queued by repeated
/// negative feedback rather than by a reader's report.
const String feedbackThresholdReason = 'feedback_threshold';

/// One entry awaiting review, as the queue lists it (`C-014` `items`).
@immutable
class QueueItem {
  const QueueItem({
    required this.entryId,
    required this.lemma,
    required this.senseLabel,
    required this.reason,
    required this.queuedAt,
    required this.state,
  });

  final String entryId;

  /// The entry's word.
  final String lemma;

  /// The entry's sense, as a plain human label.
  final String senseLabel;

  /// The reason the entry was queued: the newest report's reason, or
  /// [feedbackThresholdReason] when repeated negative feedback queued it.
  final String reason;

  /// When the entry was queued, in UTC.
  final DateTime queuedAt;

  final ReviewState state;

  /// The reason as a curator reads it.
  ///
  /// A reader's reason resolves to its own label; the feedback-threshold reason
  /// resolves to the wording the console uses for it; anything else falls back
  /// to the service's own text, so an unrecognised reason is shown rather than
  /// dropped.
  String get reasonLabel {
    final known = ReviewReason.fromWire(reason);
    if (known != null) return known.label;
    if (reason == feedbackThresholdReason) return 'Repeated negative feedback';
    return reason;
  }

  static QueueItem fromJson(Map<String, dynamic> json) {
    return QueueItem(
      entryId: json['entryId'] as String,
      lemma: json['lemma'] as String,
      senseLabel: json['senseLabel'] as String,
      reason: json['reason'] as String,
      queuedAt: DateTime.parse(json['queuedAt'] as String).toUtc(),
      state:
          ReviewState.fromWire(json['state'] as String?) ?? ReviewState.queued,
    );
  }
}

/// One page of the queue and its metadata (`C-014` 200 response).
@immutable
class ReviewQueuePage {
  const ReviewQueuePage({
    required this.items,
    required this.openCount,
    required this.page,
    required this.pageCount,
  });

  final List<QueueItem> items;

  /// The count of open items across the whole queue, for the sidebar.
  final int openCount;

  final int page;
  final int pageCount;

  static ReviewQueuePage fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as List<dynamic>)
        .map((item) => QueueItem.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
    return ReviewQueuePage(
      items: items,
      openCount: json['openCount'] as int,
      page: json['page'] as int,
      pageCount: json['pageCount'] as int,
    );
  }
}
