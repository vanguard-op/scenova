import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

/// The enable-action card (`docs/Scenova/screens/01-onboarding.md`).
///
/// It shows how to turn the Scenova action on in the reader's app, with the
/// steps for the running platform: Android registers a text-selection action,
/// iOS a share extension. When the action is off and a lookup cannot start, this
/// is what the reader is shown instead of a silent failure.
class EnableActionGuide extends StatelessWidget {
  const EnableActionGuide({
    super.key,
    this.onOpen,
    this.compact = false,
    this.openLabel = 'Open setup',
  });

  /// Opens the place where setup is finished, when one is reachable.
  final VoidCallback? onOpen;

  /// The tighter treatment used inline on Home.
  final bool compact;

  /// The label for the action that takes the reader to setup.
  final String openLabel;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;

    final title = isIOS
        ? 'Add Scenova to the share sheet'
        : 'Turn on the Scenova action';
    final steps = isIOS ? _iosSteps : _androidSteps;
    final lead = isIOS
        ? 'So a word can come straight from your book.'
        : 'So a word can come straight from your page.';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(tokens.spacing.md),
      decoration: BoxDecoration(
        color: colors.info.tint,
        borderRadius: BorderRadius.circular(ScenovaRadius.md),
        border: Border.all(color: colors.info.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AppIconView(
                icon: AppIcons.info,
                size: tokens.sizing.iconSm,
                color: colors.info.element,
              ),
              SizedBox(width: tokens.spacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: styles.body.copyWith(
                    color: colors.info.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.xs),
          Text(lead, style: styles.bodySmall.copyWith(color: colors.info.text)),
          SizedBox(height: tokens.spacing.sm),
          for (var i = 0; i < steps.length; i++) ...<Widget>[
            _Step(number: i + 1, text: steps[i]),
            if (i < steps.length - 1) SizedBox(height: tokens.spacing.xs),
          ],
          if (!compact && onOpen != null) ...<Widget>[
            SizedBox(height: tokens.spacing.sm),
            ScenovaButton(
              label: openLabel,
              onPressed: onOpen,
              variant: ScenovaButtonVariant.ghost,
            ),
          ],
        ],
      ),
    );
  }

  static const List<String> _iosSteps = <String>[
    'Select a word, then tap Share.',
    'Swipe the app row and tap More.',
    'Turn on Scenova, then tap Done.',
  ];

  static const List<String> _androidSteps = <String>[
    'Select a word to open the selection menu.',
    'Tap the three dots to see more actions.',
    'Tap Scenova to look the word up.',
  ];
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: tokens.sizing.iconSm,
          child: Text(
            '$number.',
            style: styles.caption.copyWith(color: colors.info.element),
          ),
        ),
        SizedBox(width: tokens.spacing.sm),
        Expanded(
          child: Text(
            text,
            style: styles.bodySmall.copyWith(color: colors.info.text),
          ),
        ),
      ],
    );
  }
}
