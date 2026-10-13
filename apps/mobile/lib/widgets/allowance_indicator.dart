import 'package:flutter/material.dart';

import '../models/entitlement.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// The allowance indicator on Home (`docs/Scenova/screens/02-home.md`).
///
/// It reports the entitlement state as it is: a count of lookups left, or the
/// pre-account case where lookups are free and unmetered. It never invents a
/// number.
class AllowanceIndicator extends StatelessWidget {
  const AllowanceIndicator({super.key, required this.entitlement});

  final Entitlement entitlement;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);

    final String label;
    final Color color;
    if (entitlement.unmetered) {
      label = 'Lookups are free while Scenova is in early access.';
      color = colors.textSecondary;
    } else if ((entitlement.lookupsRemaining ?? 0) <= 0) {
      label = 'You have used this month\'s lookups.';
      color = colors.warning.element;
    } else {
      final remaining = entitlement.lookupsRemaining;
      label = remaining == 1
          ? '1 lookup left this month.'
          : '$remaining lookups left this month.';
      color = colors.textSecondary;
    }

    return Semantics(
      label: label,
      child: Text(label, style: styles.bodySmall.copyWith(color: color)),
    );
  }
}
