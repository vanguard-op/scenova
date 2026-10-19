import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../models/review_entry.dart';
import '../models/review_queue.dart';

/// The Review Status Badge (`docs/Scenova/screens.md` → "Shared / Common
/// Components").
///
/// It shows the queue item's review state through the shared [StatusBadge],
/// which carries the state's own label and icon beside its colour so the state
/// never rests on colour alone.
class ReviewStatusBadge extends StatelessWidget {
  const ReviewStatusBadge({super.key, required this.state});

  final ReviewState state;

  @override
  Widget build(BuildContext context) {
    return StatusBadge(
      label: state.label,
      icon: _icon(state),
      family: _family(ScenovaColors.of(context), state),
      semanticLabel: 'Review state: ${state.label}',
    );
  }

  /// The semantic family the state reads in. Queued needs attention, reviewed
  /// is under way, and actioned is resolved.
  static ScenovaSemanticColors _family(
    ScenovaColors colors,
    ReviewState state,
  ) {
    return switch (state) {
      ReviewState.queued => colors.warning,
      ReviewState.reviewed => colors.info,
      ReviewState.actioned => colors.success,
    };
  }

  static IconData _icon(ReviewState state) {
    return switch (state) {
      ReviewState.queued => AppIcons.queued,
      ReviewState.reviewed => AppIcons.seeIt,
      ReviewState.actioned => AppIcons.actioned,
    };
  }
}

/// The library status of an entry (`docs/Scenova/screens/10-review-entry.md` →
/// Components: "Status badge").
///
/// The review state says where the entry sits in the queue; this says whether
/// the clip is in front of readers. A curator deciding whether to keep, replace,
/// or retire the clip needs both, so the two badges sit together. Like the
/// review badge it goes through the shared [StatusBadge], so the status never
/// rests on colour alone.
class EntryStatusBadge extends StatelessWidget {
  const EntryStatusBadge({super.key, required this.status});

  final EntryStatus status;

  @override
  Widget build(BuildContext context) {
    return StatusBadge(
      label: status.label,
      icon: _icon(status),
      family: _family(ScenovaColors.of(context), status),
      semanticLabel: 'Library status: ${status.label}',
    );
  }

  /// The semantic family the status reads in. Serving is resolved; retired is
  /// stopped.
  static ScenovaSemanticColors _family(
    ScenovaColors colors,
    EntryStatus status,
  ) {
    return switch (status) {
      EntryStatus.active => colors.success,
      EntryStatus.retired => colors.error,
    };
  }

  static IconData _icon(EntryStatus status) {
    return switch (status) {
      EntryStatus.active => AppIcons.check,
      EntryStatus.retired => AppIcons.remove,
    };
  }
}
