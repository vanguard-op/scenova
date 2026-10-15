import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../config.dart';
import '../models/review_queue.dart';
import '../theme/layout.dart';

/// The Filter bar (`docs/Scenova/screens/09-review-queue.md` → Components):
/// a reason select, a state select, and a word field that narrow the queue, and
/// a refresh action.
///
/// The bar is disabled while the queue is loading, so a filter cannot be
/// changed against a slice that is already stale
/// (`docs/Scenova/screens/09-review-queue.md` → Data Flow: the filters are
/// enabled on success).
class QueueFilterBar extends StatefulWidget {
  const QueueFilterBar({
    super.key,
    required this.reason,
    required this.state,
    required this.word,
    required this.enabled,
    required this.hasActiveFilters,
    required this.onReasonChanged,
    required this.onStateChanged,
    required this.onWordChanged,
    required this.onClear,
    required this.onRefresh,
  });

  final ReviewReason? reason;
  final ReviewState? state;
  final String word;
  final bool enabled;
  final bool hasActiveFilters;
  final ValueChanged<ReviewReason?> onReasonChanged;
  final ValueChanged<ReviewState?> onStateChanged;
  final ValueChanged<String> onWordChanged;
  final VoidCallback onClear;
  final VoidCallback onRefresh;

  @override
  State<QueueFilterBar> createState() => _QueueFilterBarState();
}

class _QueueFilterBarState extends State<QueueFilterBar> {
  late final TextEditingController _word = TextEditingController(
    text: widget.word,
  );
  Timer? _debounce;

  @override
  void didUpdateWidget(QueueFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A filter cleared elsewhere (the empty state's action, a reset) lands in
    // the field, so the field never shows a filter that is no longer applied.
    if (widget.word != _word.text) {
      _word.text = widget.word;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _word.dispose();
    super.dispose();
  }

  void _onWordChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(ConsoleConfig.wordFilterDebounce, () {
      if (mounted) widget.onWordChanged(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.lg),
      child: Wrap(
        spacing: tokens.spacing.md,
        runSpacing: tokens.spacing.md,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SizedBox(
            width: ConsoleLayout.filterFieldWidth,
            child: _FilterSelect<ReviewReason?>(
              label: 'Reason',
              value: widget.reason,
              enabled: widget.enabled,
              items: <DropdownMenuItem<ReviewReason?>>[
                const DropdownMenuItem<ReviewReason?>(
                  value: null,
                  child: Text('All reasons'),
                ),
                for (final reason in ReviewReason.values)
                  DropdownMenuItem<ReviewReason?>(
                    value: reason,
                    child: Text(reason.label),
                  ),
              ],
              onChanged: widget.onReasonChanged,
            ),
          ),
          SizedBox(
            width: ConsoleLayout.filterFieldWidth,
            child: _FilterSelect<ReviewState?>(
              label: 'State',
              value: widget.state,
              enabled: widget.enabled,
              items: <DropdownMenuItem<ReviewState?>>[
                const DropdownMenuItem<ReviewState?>(
                  value: null,
                  child: Text('All states'),
                ),
                for (final state in ReviewState.values)
                  DropdownMenuItem<ReviewState?>(
                    value: state,
                    child: Text(state.label),
                  ),
              ],
              onChanged: widget.onStateChanged,
            ),
          ),
          SizedBox(
            width: ConsoleLayout.filterFieldWidth,
            child: TextField(
              controller: _word,
              enabled: widget.enabled,
              onChanged: _onWordChanged,
              style: styles.body.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Word',
                hintText: 'Filter by word',
                suffixIcon: widget.word.isEmpty
                    ? null
                    : ScenovaIconButton(
                        icon: AppIcons.close,
                        tooltip: 'Clear the word filter',
                        onPressed: () {
                          _word.clear();
                          widget.onWordChanged('');
                        },
                      ),
              ),
              textInputAction: TextInputAction.search,
            ),
          ),
          if (widget.hasActiveFilters)
            ScenovaButton(
              label: 'Clear filters',
              variant: ScenovaButtonVariant.ghost,
              icon: AppIcons.close,
              onPressed: widget.enabled ? widget.onClear : null,
            ),
          ScenovaButton(
            label: 'Refresh',
            variant: ScenovaButtonVariant.outline,
            icon: AppIcons.retry,
            onPressed: widget.enabled ? widget.onRefresh : null,
          ),
        ],
      ),
    );
  }
}

/// A labelled select for the filter bar.
///
/// It is a Material dropdown with the theme's input decoration, so it carries
/// the same border, fill, focus ring, and height as the word field beside it.
/// `X` is the full option type — `ReviewReason?`, say — so the "All" option is
/// one of the values rather than a special case.
class _FilterSelect<X> extends StatelessWidget {
  const _FilterSelect({
    required this.label,
    required this.value,
    required this.items,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final X value;
  final List<DropdownMenuItem<X>> items;
  final bool enabled;
  final ValueChanged<X?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    final tokens = ScenovaTokens.of(context);

    return DropdownButtonFormField<X>(
      initialValue: value,
      isDense: true,
      isExpanded: true,
      dropdownColor: colors.surface,
      style: styles.body.copyWith(color: colors.textPrimary),
      icon: AppIconView(icon: AppIcons.expand, size: tokens.sizing.iconSm),
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: enabled ? onChanged : null,
    );
  }
}
