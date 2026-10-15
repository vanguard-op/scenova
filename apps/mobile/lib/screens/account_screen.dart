import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../models/entitlement.dart';
import '../services/app_services.dart';
import 'account_controller.dart';

/// Screen 8: Account (`docs/Scenova/screens/08-account.md`).
///
/// Sign in, see the plan and the allowance left this month, and manage Pro or a
/// top-up. The plan card is the visual focus. Every state from the screen spec
/// is covered: loading, signed out, Free, Pro, Trial, purchasing, purchase
/// failed, the store unreachable, and the entitlement read failing.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, this.controller});

  /// The controller to drive the screen with.
  ///
  /// When it is not given the screen builds one from the services in scope and
  /// loads it; a caller that passes one owns its load and disposal. The preview
  /// gallery drives a purchase through it so the purchasing and failure states
  /// can be looked at.
  final AccountController? controller;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  AccountController? _controller;

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
    // The services are read here rather than in initState so the inherited
    // scope is safe to depend on.
    final services = ScenovaScope.of(context);
    final controller = AccountController(
      entitlements: services.entitlementsApi,
      session: services.accountSession,
      purchases: services.purchases,
      plan: services.entitlements,
    );
    _controller = controller;
    controller.addListener(_onChanged);
    controller.load();
  }

  @override
  void dispose() {
    // A controller the screen built is its own; an injected one belongs to its
    // caller, so only the listener is dropped here.
    _controller?.removeListener(_onChanged);
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.lg),
          child: _body(context, _controller!),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AccountController controller) {
    final tokens = ScenovaTokens.of(context);

    switch (controller.status) {
      case AccountStatus.loading:
        return ListView(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.md),
          children: const <Widget>[SkeletonList(rows: 3)],
        );
      case AccountStatus.error:
        return ErrorState(
          headline: 'Your plan did not load',
          body: 'Check your connection and try again.',
          onRetry: controller.load,
        );
      case AccountStatus.signedOut:
        return _SignedOut(controller: controller);
      case AccountStatus.ready:
        return _Plan(
          controller: controller,
          entitlement: controller.entitlement ?? Entitlement.signedOut,
        );
    }
  }
}

/// The signed-out state: the prompt to sign in
/// (`docs/Scenova/screens/08-account.md` → "Signed out").
class _SignedOut extends StatelessWidget {
  const _SignedOut({required this.controller});

  final AccountController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final message = controller.actionError;

    return Column(
      children: <Widget>[
        if (message != null) ...<Widget>[
          SizedBox(height: tokens.spacing.md),
          _ActionNotice(
            message: message,
            onRetry: controller.canRetry ? controller.retry : null,
          ),
        ],
        Expanded(
          child: EmptyState(
            icon: AppIcons.account,
            headline: 'Sign in to Scenova',
            body:
                'Sign in to see your plan and keep your lookups with you, on '
                'any device.',
            actionLabel: 'Sign in',
            onAction: controller.signIn,
          ),
        ),
      ],
    );
  }
}

/// The signed-in state: the plan card, the primary action, and the two
/// secondary rows (`docs/Scenova/screens/08-account.md` → Layout).
class _Plan extends StatelessWidget {
  const _Plan({required this.controller, required this.entitlement});

  final AccountController controller;
  final Entitlement entitlement;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final message = controller.actionError;
    // The reader manages a plan they already hold; anyone else starts one.
    final manages = entitlement.isPro || entitlement.isTrial;

    return ListView(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.md),
      children: <Widget>[
        _PlanCard(entitlement: entitlement),
        SizedBox(height: tokens.spacing.lg),
        ScenovaButton(
          label: manages ? 'Manage plan' : 'Start Pro',
          expanded: true,
          isSubmitting: controller.purchasing,
          onPressed: controller.busy
              ? null
              : (manages ? controller.managePlan : controller.startPro),
        ),
        if (message != null) ...<Widget>[
          SizedBox(height: tokens.spacing.md),
          _ActionNotice(
            message: message,
            onRetry: controller.canRetry ? controller.retry : null,
          ),
        ],
        SizedBox(height: tokens.spacing.xl),
        ScenovaButton(
          label: 'Restore purchases',
          variant: ScenovaButtonVariant.outline,
          expanded: true,
          onPressed: controller.busy ? null : controller.restorePurchases,
        ),
        SizedBox(height: tokens.spacing.sm),
        ScenovaButton(
          label: 'Sign out',
          variant: ScenovaButtonVariant.ghost,
          expanded: true,
          onPressed: controller.busy ? null : controller.signOut,
        ),
      ],
    );
  }
}

/// The plan and the allowance meter (`docs/Scenova/screens/08-account.md` →
/// Components: Plan card, Allowance meter).
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.entitlement});

  final Entitlement entitlement;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final limit = entitlement.lookupsLimit;
    final used = entitlement.lookupsUsed ?? 0;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(tokens.spacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        // The card sits on the base surface and carries `shadow-sm`
        // (`docs/Scenova/branding.md` → "Shadows").
        boxShadow: tokens.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Your plan',
            style: styles.caption.copyWith(color: colors.textSecondary),
          ),
          SizedBox(height: tokens.spacing.xs),
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  _planName(entitlement),
                  style: styles.h1.copyWith(color: colors.textPrimary),
                ),
              ),
              if (entitlement.isTrial) ...<Widget>[
                SizedBox(width: tokens.spacing.sm),
                StatusBadge(
                  label: 'Trial',
                  icon: AppIcons.info,
                  family: colors.info,
                  semanticLabel: 'Trial',
                ),
              ],
            ],
          ),
          if (entitlement.isTrial &&
              entitlement.trialEndsAt != null) ...<Widget>[
            SizedBox(height: tokens.spacing.xs),
            Text(
              'Your free trial ends ${_formatDate(context, entitlement.trialEndsAt!)}.',
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
            ),
          ],
          if (limit != null) ...<Widget>[
            SizedBox(height: tokens.spacing.md),
            _AllowanceMeter(used: used, limit: limit),
            SizedBox(height: tokens.spacing.sm),
            Text(
              _meterNote(context, entitlement, used, limit),
              style: styles.bodySmall.copyWith(
                color: entitlement.exhausted
                    ? colors.warning.element
                    : colors.textSecondary,
              ),
            ),
          ],
          if (entitlement.status != EntitlementStatus.active) ...<Widget>[
            SizedBox(height: tokens.spacing.md),
            _StatusNote(status: entitlement.status),
          ],
        ],
      ),
    );
  }

  String _planName(Entitlement entitlement) {
    return switch (entitlement.tier) {
      PlanTier.pro || PlanTier.trial => 'Pro',
      PlanTier.free || PlanTier.guest => 'Free',
    };
  }

  String _meterNote(
    BuildContext context,
    Entitlement entitlement,
    int used,
    int limit,
  ) {
    if (entitlement.exhausted) {
      return 'You have used this month\'s lookups.';
    }
    if (entitlement.periodEnd != null) {
      return 'Lookups reset ${_formatDate(context, entitlement.periodEnd!)}.';
    }
    return '$used of $limit lookups used this month.';
  }
}

/// The lookups used against the allowance
/// (`docs/Scenova/screens/08-account.md` → "Allowance meter").
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
    final exhausted = used >= limit;
    final spoken = exhausted
        ? 'You have used this month\'s lookups.'
        : '$used of $limit lookups used this month.';

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
            color: exhausted ? colors.warning.element : null,
            semanticsLabel: spoken,
          ),
        ),
      ],
    );
  }
}

/// The note shown when the account is in grace or has lapsed (`C-018`,
/// `status`).
class _StatusNote extends StatelessWidget {
  const _StatusNote({required this.status});

  final EntitlementStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final expired = status == EntitlementStatus.expired;
    final family = expired ? colors.warning : colors.info;
    final message = expired
        ? 'Your plan has ended. Renew to keep Pro.'
        : 'Your plan stays active while a payment is sorted out.';

    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.xs),
            child: AppIconView(
              icon: expired ? AppIcons.warning : AppIcons.info,
              size: tokens.sizing.iconSm,
              color: family.element,
            ),
          ),
          SizedBox(width: tokens.spacing.sm),
          Expanded(
            child: Text(
              message,
              style: styles.bodySmall.copyWith(color: family.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// The inline message beside the actions when a purchase, restore, sign-in, or
/// sign-out did not go through, with a retry
/// (`docs/Scenova/screens/08-account.md` → "Purchase failed").
class _ActionNotice extends StatelessWidget {
  const _ActionNotice({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(tokens.spacing.md),
        decoration: BoxDecoration(
          color: colors.error.tint,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
          border: Border.all(color: colors.error.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.xs),
                  child: AppIconView(
                    icon: AppIcons.error,
                    size: tokens.sizing.iconSm,
                    color: colors.error.element,
                  ),
                ),
                SizedBox(width: tokens.spacing.sm),
                Expanded(
                  child: Text(
                    message,
                    style: styles.bodySmall.copyWith(color: colors.error.text),
                  ),
                ),
              ],
            ),
            if (onRetry != null) ...<Widget>[
              SizedBox(height: tokens.spacing.xs),
              ScenovaButton(
                label: 'Try again',
                variant: ScenovaButtonVariant.ghost,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A date in the reader's locale, as the platform's own medium form.
String _formatDate(BuildContext context, DateTime date) {
  return MaterialLocalizations.of(context).formatMediumDate(date);
}
