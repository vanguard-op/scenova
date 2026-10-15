import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../format/relative_age.dart';
import '../models/review_queue.dart';
import '../theme/layout.dart';
import 'status_badge.dart';

/// The Queue table (`docs/Scenova/screens/09-review-queue.md` → Components):
/// one row per entry awaiting review, with columns for word, sense, reason,
/// age, and state.
///
/// The whole row is the primary action — opening the entry — so it is one
/// focusable, keyboard-activatable control rather than a row with a small link
/// inside it.
class QueueTable extends StatelessWidget {
  const QueueTable({super.key, required this.items, required this.onOpen});

  final List<QueueItem> items;
  final ValueChanged<QueueItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        color: colors.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _QueueHeaderRow(),
          for (final item in items)
            _QueueRow(item: item, onOpen: () => onOpen(item)),
        ],
      ),
    );
  }
}

/// The header row. It names each column and is not interactive.
class _QueueHeaderRow extends StatelessWidget {
  const _QueueHeaderRow();

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Container(
      color: colors.surfaceSecondary,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.lg,
        vertical: tokens.spacing.md,
      ),
      child: Row(
        children: <Widget>[
          _HeaderCell('Word', flex: ConsoleLayout.wordColumnFlex),
          _HeaderCell('Sense', flex: ConsoleLayout.senseColumnFlex),
          _HeaderCell('Reason', flex: ConsoleLayout.reasonColumnFlex),
          _HeaderCell('Age', flex: ConsoleLayout.ageColumnFlex),
          _HeaderCell('State', flex: ConsoleLayout.stateColumnFlex),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.label, {required this.flex});

  final String label;
  final int flex;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    return Expanded(
      flex: flex,
      child: Padding(
        padding: EdgeInsets.only(right: tokens.spacing.md),
        child: Semantics(
          header: true,
          child: Text(
            label,
            style: styles.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// One table cell: the column's weight, with the gutter that keeps a long
/// value from running into the column beside it.
class _TableCell extends StatelessWidget {
  const _TableCell({required this.flex, required this.child});

  final int flex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: EdgeInsets.only(right: ScenovaTokens.of(context).spacing.md),
        child: child,
      ),
    );
  }
}

/// One row: the entry, opening on activation.
class _QueueRow extends StatefulWidget {
  const _QueueRow({required this.item, required this.onOpen});

  final QueueItem item;
  final VoidCallback onOpen;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final item = widget.item;

    return FocusRing(
      visible: _focused,
      radius: ScenovaRadius.lg,
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Semantics(
          button: true,
          label:
              'Open ${item.lemma}, sense ${item.senseLabel}, '
              '${item.reasonLabel}, queued ${relativeAge(item.queuedAt)}, '
              '${item.state.label}',
          child: Material(
            color: colors.surface,
            child: InkWell(
              onTap: widget.onOpen,
              hoverColor: colors.surfaceSecondary,
              // Focus is the ring, not a fill, so the row's text keeps its
              // contrast while it is focused.
              focusColor: Colors.transparent,
              child: ExcludeSemantics(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: colors.border)),
                  ),
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.lg,
                    vertical: tokens.spacing.md,
                  ),
                  child: Row(
                    children: <Widget>[
                      _TableCell(
                        flex: ConsoleLayout.wordColumnFlex,
                        child: Tooltip(
                          message: item.lemma,
                          child: Text(
                            item.lemma,
                            style: styles.body.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      _TableCell(
                        flex: ConsoleLayout.senseColumnFlex,
                        child: Text(
                          item.senseLabel,
                          style: styles.body.copyWith(
                            color: colors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _TableCell(
                        flex: ConsoleLayout.reasonColumnFlex,
                        child: Tooltip(
                          message: item.reasonLabel,
                          child: Text(
                            item.reasonLabel,
                            style: styles.body.copyWith(
                              color: colors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      _TableCell(
                        flex: ConsoleLayout.ageColumnFlex,
                        child: Text(
                          relativeAge(item.queuedAt),
                          style: styles.body.copyWith(
                            color: colors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        flex: ConsoleLayout.stateColumnFlex,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ReviewStatusBadge(state: item.state),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The queue's loading placeholder: the table's shape, held still
/// (`docs/Scenova/screens/09-review-queue.md` → Loading).
class QueueTableSkeleton extends StatelessWidget {
  const QueueTableSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        color: colors.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _QueueHeaderRow(),
          for (var i = 0; i < rows; i++)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.border)),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.lg,
                vertical: tokens.spacing.md,
              ),
              child: Row(
                children: <Widget>[
                  _TableCell(
                    flex: ConsoleLayout.wordColumnFlex,
                    child: const SkeletonLine(widthFactor: 0.7, height: 16),
                  ),
                  _TableCell(
                    flex: ConsoleLayout.senseColumnFlex,
                    child: const SkeletonLine(widthFactor: 0.3, height: 16),
                  ),
                  _TableCell(
                    flex: ConsoleLayout.reasonColumnFlex,
                    child: const SkeletonLine(widthFactor: 0.6, height: 16),
                  ),
                  _TableCell(
                    flex: ConsoleLayout.ageColumnFlex,
                    child: const SkeletonLine(widthFactor: 0.5, height: 16),
                  ),
                  _TableCell(
                    flex: ConsoleLayout.stateColumnFlex,
                    child: const SkeletonLine(widthFactor: 0.6, height: 16),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
