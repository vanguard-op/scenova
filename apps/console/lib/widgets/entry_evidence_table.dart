import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:scenova_design/scenova_design.dart';

import '../format/relative_age.dart';
import '../models/review_entry.dart';
import '../theme/layout.dart';

/// The Evidence table (`docs/Scenova/screens/10-review-entry.md` → Components):
/// the reports and the negative feedback against the entry, beside the clip.
///
/// It is the case for the decision, so it shows every report with its reason
/// and the reader's note, and every negative rating, newest first. The time
/// reads as an age with the absolute time on hover, matching the queue's age
/// column.
class EntryEvidenceTable extends StatelessWidget {
  const EntryEvidenceTable({super.key, required this.detail});

  final ReviewEntryDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Evidence', style: styles.h3.copyWith(color: colors.textPrimary)),
        SizedBox(height: tokens.spacing.md),
        _Section(
          title: 'Reports',
          columns: const <_Column>[
            _Column('Reason', ConsoleLayout.evidenceReasonFlex),
            _Column('Note', ConsoleLayout.evidenceNoteFlex),
            _Column('When', ConsoleLayout.evidenceWhenFlex),
          ],
          rows: <List<Widget>>[
            for (final report in detail.reports)
              <Widget>[
                _Text(report.reasonLabel),
                _Text(
                  report.note == null || report.note!.isEmpty
                      ? 'No note'
                      : report.note!,
                  muted: report.note == null || report.note!.isEmpty,
                ),
                _When(report.createdAt),
              ],
          ],
          emptyLabel: 'No reader reports against this entry.',
        ),
        SizedBox(height: tokens.spacing.lg),
        _Section(
          title: 'Negative feedback',
          columns: const <_Column>[
            _Column('Rating', ConsoleLayout.feedbackRatingFlex),
            _Column('When', ConsoleLayout.feedbackWhenFlex),
          ],
          rows: <List<Widget>>[
            for (final rating in detail.feedback)
              <Widget>[_Text(rating.rating.label), _When(rating.createdAt)],
          ],
          emptyLabel: 'No negative feedback against this entry.',
        ),
      ],
    );
  }
}

/// One column: its header and its weight.
class _Column {
  const _Column(this.label, this.flex);

  final String label;
  final int flex;
}

/// A titled table with a header row and its rows, or a line explaining that
/// there are none.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.columns,
    required this.rows,
    required this.emptyLabel,
  });

  final String title;
  final List<_Column> columns;
  final List<List<Widget>> rows;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

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
          Container(
            color: colors.surfaceSecondary,
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.lg,
              vertical: tokens.spacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  title,
                  style: styles.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: tokens.spacing.sm),
                Row(
                  children: <Widget>[
                    for (final column in columns)
                      _Cell(
                        flex: column.flex,
                        child: Semantics(
                          header: true,
                          child: Text(
                            column.label,
                            style: styles.caption.copyWith(
                              color: colors.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.lg,
                vertical: tokens.spacing.md,
              ),
              child: Text(
                emptyLabel,
                style: styles.bodySmall.copyWith(color: colors.textSecondary),
              ),
            )
          else
            for (final row in rows)
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.border)),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.lg,
                  vertical: tokens.spacing.md,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (var i = 0; i < row.length; i++)
                      _Cell(flex: columns[i].flex, child: row[i]),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// One table cell: the column's weight, with the gutter that keeps a long
/// value from running into the column beside it.
class _Cell extends StatelessWidget {
  const _Cell({required this.flex, required this.child});

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

class _Text extends StatelessWidget {
  const _Text(this.value, {this.muted = false});

  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    return Text(
      value,
      style: styles.body.copyWith(
        color: muted ? colors.textSecondary : colors.textPrimary,
      ),
    );
  }
}

/// When the evidence was recorded: its age, with the absolute time on hover.
class _When extends StatelessWidget {
  const _When(this.at);

  final DateTime at;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    return Tooltip(
      message: DateFormat.yMMMd().add_jm().format(at.toLocal()),
      child: Text(
        relativeAge(at),
        style: styles.body.copyWith(color: colors.textSecondary),
      ),
    );
  }
}
