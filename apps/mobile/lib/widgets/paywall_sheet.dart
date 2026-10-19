import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../models/entitlement.dart';
import '../screens/paywall_controller.dart';
import '../services/app_services.dart';
import '../services/purchase_service.dart';
import 'sign_in_sheet.dart';

/// Opens the Paywall sheet over the Clip View
/// (`docs/Scenova/screens/04-paywall.md`).
///
/// The sheet returns what came of the reader's visit — [PaywallOutcome.proStarted]
/// or [PaywallOutcome.topUpBought] — or null when they continued without a clip.
/// A purchase the store could not complete is handled inside the sheet, which
/// stays open with an inline message and a retry.
Future<PaywallOutcome?> showPaywallSheet(
  BuildContext context, {
  required Entitlement entitlement,
  PaywallController? controller,
}) {
  return showModalBottomSheet<PaywallOutcome>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _PaywallSheet(entitlement: entitlement, controller: controller),
  );
}

/// The Paywall sheet's content: the allowance meter, the Pro option, the top-up
/// option, and the actions (`docs/Scenova/screens/04-paywall.md` → Layout).
///
/// Every state from the screen spec is covered: default, purchasing, purchase
/// failed, and signed out, with the store-unreachable edge case. A reader who
/// already holds Pro is not sold Pro again, and a plan being removed is shown
/// without starting a new charge.
class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet({required this.entitlement, this.controller});

  /// The reader's plan and the lookups they have spent, for the meter.
  final Entitlement entitlement;

  /// The controller to drive the sheet with. When it is not given the sheet
  /// builds one from the services in scope and loads it; a caller that passes
  /// one owns its load and disposal.
  final PaywallController? controller;

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  PaywallController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final injected = widget.controller;
    if (injected != null) {
      _controller = injected;
      injected.addListener(_onChanged);
      return;
    }
    final services = ScenovaScope.of(context);
    final controller = PaywallController(
      entitlement: widget.entitlement,
      purchases: services.purchases,
      plan: services.entitlements,
      analytics: services.analytics,
    );
    _controller = controller;
    controller.addListener(_onChanged);
    controller.load();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _purchase(Future<PaywallOutcome?> Function() action) async {
    final outcome = await action();
    if (!mounted || outcome == null) return;
    Navigator.of(context).pop(outcome);
  }

  /// Opens the sign-in sheet and, once the reader holds an account, reads the
  /// plan it holds and the store's offering (`FEAT-013`, D-032).
  Future<void> _signIn() async {
    final controller = _controller;
    if (controller == null) return;
    final signedIn = await showSignInSheet(context);
    if (!mounted || !signedIn) return;
    await controller.signedIn();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    // The sheet grows with the keyboard on the platforms that show one, and is
    // scrollable so a short window never clips an option.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.lg,
            0,
            tokens.spacing.lg,
            tokens.spacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _content(context, _controller!),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, PaywallController controller) {
    final tokens = ScenovaTokens.of(context);
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);
    final limit = widget.entitlement.lookupsLimit;
    final used = widget.entitlement.lookupsUsed ?? 0;

    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          'You\'ve used this month\'s lookups',
          style: styles.h3.copyWith(color: colors.textPrimary),
        ),
      ),
    ];

    if (limit != null) {
      children
        ..add(SizedBox(height: tokens.spacing.md))
        ..add(_AllowanceMeter(used: used, limit: limit));
    }

    switch (controller.status) {
      case PaywallStatus.loading:
        children
          ..add(SizedBox(height: tokens.spacing.lg))
          ..add(const SkeletonList(rows: 2));
      case PaywallStatus.signedOut:
        children
          ..add(SizedBox(height: tokens.spacing.lg))
          ..addAll(_signedOut(context, controller));
      case PaywallStatus.storeUnavailable:
        children
          ..add(SizedBox(height: tokens.spacing.lg))
          ..addAll(
            _unreachable(
              context,
              controller,
              message:
                  'The store is not reachable right now. You can keep reading '
                  'without a clip.',
            ),
          );
      case PaywallStatus.error:
        children
          ..add(SizedBox(height: tokens.spacing.lg))
          ..addAll(
            _unreachable(
              context,
              controller,
              message:
                  'The plans could not be loaded just now. You can keep reading '
                  'without a clip.',
            ),
          );
      case PaywallStatus.ready:
        children
          ..add(SizedBox(height: tokens.spacing.lg))
          ..addAll(_options(context, controller));
    }
    return children;
  }

  /// The plans, the prices, and the three actions
  /// (`docs/Scenova/screens/04-paywall.md` → Components).
  List<Widget> _options(BuildContext context, PaywallController controller) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final offering = controller.offering!;
    final purchasing = controller.purchasing;
    final busy = controller.busy;
    final refunding = controller.refundInProgress;
    // A reader who already holds Pro is not sold Pro again, and a plan being
    // removed starts no new charge; the top-up stays available to the first
    // (`docs/Scenova/screens/04-paywall.md` → Edge Cases).
    final sellPro = !controller.alreadyPro && !refunding;
    final sellTopUp = !refunding;

    return <Widget>[
      if (controller.actionError != null) ...<Widget>[
        _Notice(message: controller.actionError!),
        SizedBox(height: tokens.spacing.md),
      ],
      if (sellPro) ...<Widget>[
        _ProCard(offering: offering),
        SizedBox(height: tokens.spacing.md),
      ],
      if (sellTopUp) ...<Widget>[
        _TopUpCard(offering: offering),
        SizedBox(height: tokens.spacing.md),
      ],
      if (refunding) ...<Widget>[
        Text(
          'Your plan is being removed, so nothing is charged here.',
          style: styles.bodySmall.copyWith(color: colors.textSecondary),
        ),
        SizedBox(height: tokens.spacing.md),
      ],
      if (sellPro)
        ScenovaButton(
          label: 'Start Pro',
          expanded: true,
          isSubmitting: purchasing == PaywallAction.startPro,
          onPressed: busy
              ? null
              : () => unawaited(_purchase(controller.startPro)),
        ),
      if (sellPro && sellTopUp) SizedBox(height: tokens.spacing.sm),
      if (sellTopUp)
        ScenovaButton(
          label: 'Buy a top-up',
          variant: ScenovaButtonVariant.outline,
          expanded: true,
          isSubmitting: purchasing == PaywallAction.topUp,
          onPressed: busy
              ? null
              : () => unawaited(_purchase(controller.buyTopUp)),
        ),
      SizedBox(height: tokens.spacing.sm),
      ScenovaButton(
        label: 'Continue without a clip',
        variant: ScenovaButtonVariant.ghost,
        expanded: true,
        onPressed: busy ? null : () => Navigator.of(context).pop(),
      ),
      if (controller.canRetry && !busy) ...<Widget>[
        SizedBox(height: tokens.spacing.sm),
        ScenovaButton(
          label: 'Try again',
          variant: ScenovaButtonVariant.ghost,
          icon: AppIcons.retry,
          expanded: true,
          onPressed: () => unawaited(_purchase(controller.retry)),
        ),
      ],
    ];
  }

  /// The signed-out state: the prompt to sign in first
  /// (`docs/Scenova/screens/04-paywall.md` → "Signed out").
  List<Widget> _signedOut(BuildContext context, PaywallController controller) {
    final tokens = ScenovaTokens.of(context);
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);

    return <Widget>[
      Text(
        'Sign in first',
        style: styles.bodyLarge.copyWith(color: colors.textPrimary),
      ),
      SizedBox(height: tokens.spacing.xs),
      Text(
        'Sign in to add lookups and keep them with you on any device.',
        style: styles.bodySmall.copyWith(color: colors.textSecondary),
      ),
      if (controller.actionError != null) ...<Widget>[
        SizedBox(height: tokens.spacing.md),
        _Notice(message: controller.actionError!),
      ],
      SizedBox(height: tokens.spacing.lg),
      ScenovaButton(
        label: 'Sign in',
        expanded: true,
        onPressed: () => unawaited(_signIn()),
      ),
      SizedBox(height: tokens.spacing.sm),
      ScenovaButton(
        label: 'Continue without a clip',
        variant: ScenovaButtonVariant.ghost,
        expanded: true,
        onPressed: controller.busy ? null : () => Navigator.of(context).pop(),
      ),
    ];
  }

  /// The store-unreachable and offering-error states: the reader is told and can
  /// keep reading without a clip (`docs/Scenova/screens/04-paywall.md` → Edge
  /// Cases).
  List<Widget> _unreachable(
    BuildContext context,
    PaywallController controller, {
    required String message,
  }) {
    final tokens = ScenovaTokens.of(context);
    final colors = ScenovaColors.of(context);

    return <Widget>[
      _Callout(tone: colors.warning, icon: AppIcons.offline, message: message),
      SizedBox(height: tokens.spacing.lg),
      ScenovaButton(
        label: 'Try again',
        variant: ScenovaButtonVariant.outline,
        icon: AppIcons.retry,
        expanded: true,
        onPressed: controller.busy ? null : () => unawaited(controller.load()),
      ),
      SizedBox(height: tokens.spacing.sm),
      ScenovaButton(
        label: 'Continue without a clip',
        variant: ScenovaButtonVariant.ghost,
        expanded: true,
        onPressed: controller.busy ? null : () => Navigator.of(context).pop(),
      ),
    ];
  }
}

/// The lookups used against the allowance
/// (`docs/Scenova/screens/04-paywall.md` → "Allowance meter").
class _AllowanceMeter extends StatelessWidget {
  const _AllowanceMeter({required this.used, required this.limit});

  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final fraction = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Lookups this month',
                style: styles.bodySmall.copyWith(color: colors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(width: tokens.spacing.sm),
            Text(
              '$used of $limit',
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
        SizedBox(height: tokens.spacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(ScenovaRadius.full),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: tokens.spacing.sm,
            color: colors.warning.element,
            semanticsLabel: '$used of $limit lookups used this month.',
          ),
        ),
      ],
    );
  }
}

/// The Pro option: the price and the 7-day trial
/// (`docs/Scenova/screens/04-paywall.md` → "Pro option").
class _ProCard extends StatelessWidget {
  const _ProCard({required this.offering});

  final StoreOffering offering;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final annual = offering.proAnnual;

    return _OptionCard(
      title: 'Pro',
      trailing: StatusBadge(
        label: '${offering.trialDays}-day free trial',
        icon: AppIcons.info,
        family: colors.info,
        semanticLabel: '${offering.trialDays}-day free trial',
      ),
      price: _price(offering.proMonthly),
      detail: annual == null
          ? '50 lookups a month, and every clip kept for offline.'
          : '50 lookups a month, and every clip kept for offline. '
                'Or ${_price(annual)}.',
    );
  }
}

/// The top-up option: the price
/// (`docs/Scenova/screens/04-paywall.md` → "Top-up option").
class _TopUpCard extends StatelessWidget {
  const _TopUpCard({required this.offering});

  final StoreOffering offering;

  @override
  Widget build(BuildContext context) {
    return _OptionCard(
      title: '${offering.topUpLookups} more lookups',
      price: _price(offering.topUp),
      detail: 'Added to this month. They don\'t carry over.',
    );
  }
}

/// A store price with its period, as the store renders it.
String _price(StoreProduct product) {
  final period = product.displayPeriod;
  return period == null
      ? product.displayPrice
      : '${product.displayPrice} a $period';
}

/// One option's card: its title, its price, and a line of detail.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.title,
    required this.price,
    required this.detail,
    this.trailing,
  });

  final String title;
  final String price;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(tokens.spacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: styles.bodyLarge.copyWith(color: colors.textPrimary),
                ),
              ),
              if (trailing != null) ...<Widget>[
                SizedBox(width: tokens.spacing.sm),
                trailing!,
              ],
            ],
          ),
          SizedBox(height: tokens.spacing.xs),
          Text(price, style: styles.h3.copyWith(color: colors.textPrimary)),
          SizedBox(height: tokens.spacing.xs),
          Text(
            detail,
            style: styles.bodySmall.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// The inline message shown when a purchase did not go through
/// (`docs/Scenova/screens/04-paywall.md` → "Purchase failed").
class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _Callout(
      tone: ScenovaColors.of(context).error,
      icon: AppIcons.error,
      message: message,
    );
  }
}

/// A short note in the sheet's own tone, in a semantic family.
class _Callout extends StatelessWidget {
  const _Callout({
    required this.tone,
    required this.icon,
    required this.message,
  });

  final ScenovaSemanticColors tone;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(tokens.spacing.md),
        decoration: BoxDecoration(
          color: tone.tint,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AppIconView(
              icon: icon,
              size: tokens.sizing.iconSm,
              color: tone.element,
            ),
            SizedBox(width: tokens.spacing.sm),
            Expanded(
              child: Text(
                message,
                style: styles.bodySmall.copyWith(color: tone.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
