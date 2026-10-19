import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'brand_lockup.dart';
import 'focus_ring.dart';
import 'scenova_button.dart';

/// The Console Shell (`docs/Scenova/screens.md` → "Shared / Common
/// Components"): a sticky top bar with the product mark, the operator's
/// identity, and sign-out, and a Sidebar with the queue link and the count of
/// open items.
///
/// The shell is the frame every console screen sits in, so the chrome does not
/// move when a curator opens an entry and returns. The body scrolls; the top
/// bar and the sidebar hold.
///
/// Its chrome dimensions belong to the shell rather than to the brand, which
/// fixes only the spacing, sizing, radius, shadow, and type scales.
class ConsoleShell extends StatelessWidget {
  const ConsoleShell({
    super.key,
    required this.operatorLabel,
    required this.openCount,
    required this.queueSelected,
    required this.onOpenQueue,
    required this.onSignOut,
    required this.child,
  });

  /// The sidebar's width. Wide enough for the queue label and its count, and
  /// narrow enough to leave the table room.
  static const double sidebarWidth = 248;

  /// The sticky top bar's height, holding the mark and the operator's identity.
  static const double topBarHeight = 64;

  /// The body's maximum width, so the table does not stretch to an unreadable
  /// width on a very wide display.
  static const double contentMaxWidth = 1440;

  /// The width the operator's identity is held to before it truncates, so a
  /// long address never crowds out sign-out.
  static const double operatorLabelMaxWidth = 260;

  /// The signed-in operator, as the top bar shows them.
  final String operatorLabel;

  /// The count of open items, or null while the queue has not loaded.
  final int? openCount;

  /// Whether the queue is the screen on view.
  final bool queueSelected;

  final VoidCallback onOpenQueue;
  final VoidCallback onSignOut;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);

    return Scaffold(
      backgroundColor: colors.surface,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TopBar(operatorLabel: operatorLabel, onSignOut: onSignOut),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Sidebar(
                  openCount: openCount,
                  selected: queueSelected,
                  onOpenQueue: onOpenQueue,
                ),
                Expanded(
                  child: ColoredBox(
                    color: colors.surface,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: contentMaxWidth,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.operatorLabel, required this.onSignOut});

  final String operatorLabel;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Container(
      height: ConsoleShell.topBarHeight,
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
        boxShadow: tokens.shadowSm,
      ),
      child: Row(
        children: <Widget>[
          BrandLockup(style: styles.h3),
          SizedBox(width: tokens.spacing.sm),
          Text(
            'Review console',
            style: styles.bodySmall.copyWith(color: colors.textSecondary),
          ),
          const Spacer(),
          AppIconView(
            icon: AppIcons.account,
            size: tokens.sizing.iconSm,
            color: colors.iconDefault,
          ),
          SizedBox(width: tokens.spacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: ConsoleShell.operatorLabelMaxWidth,
            ),
            child: Text(
              operatorLabel,
              style: styles.bodySmall.copyWith(color: colors.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: tokens.spacing.md),
          ScenovaButton(
            label: 'Sign out',
            variant: ScenovaButtonVariant.ghost,
            icon: AppIcons.signOut,
            onPressed: onSignOut,
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.openCount,
    required this.selected,
    required this.onOpenQueue,
  });

  final int? openCount;
  final bool selected;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);

    return Container(
      width: ConsoleShell.sidebarWidth,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      padding: EdgeInsets.all(tokens.spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SidebarLink(
            icon: AppIcons.queue,
            label: 'Review queue',
            count: openCount,
            selected: selected,
            onTap: onOpenQueue,
          ),
        ],
      ),
    );
  }
}

/// One sidebar link: an icon, a label, and an optional count.
class _SidebarLink extends StatefulWidget {
  const _SidebarLink({
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarLink> createState() => _SidebarLinkState();
}

class _SidebarLinkState extends State<_SidebarLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final count = widget.count;

    return FocusRing(
      visible: _focused,
      radius: ScenovaRadius.md,
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: count == null ? widget.label : '${widget.label}, $count open',
          child: Material(
            color: widget.selected ? colors.primaryTint : colors.surface,
            borderRadius: BorderRadius.circular(ScenovaRadius.md),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(ScenovaRadius.md),
              hoverColor: widget.selected
                  ? colors.primaryTint
                  : colors.surfaceSecondary,
              focusColor: Colors.transparent,
              child: Container(
                height: tokens.sizing.buttonHeight,
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.md),
                child: Row(
                  children: <Widget>[
                    AppIconView(
                      icon: widget.icon,
                      active: widget.selected,
                      size: tokens.sizing.iconMd,
                    ),
                    SizedBox(width: tokens.spacing.sm),
                    Expanded(
                      child: Text(
                        widget.label,
                        style: styles.body.copyWith(
                          color: widget.selected
                              ? colors.primaryDeep
                              : colors.textPrimary,
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (count != null)
                      _CountPill(count: count, selected: widget.selected),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Container(
      constraints: BoxConstraints(minWidth: tokens.sizing.iconMd),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.sm,
        vertical: tokens.spacing.xs,
      ),
      decoration: BoxDecoration(
        color: selected ? colors.primary : colors.surfaceSecondary,
        borderRadius: BorderRadius.circular(ScenovaRadius.full),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: styles.caption.copyWith(
          color: selected ? colors.onSolid : colors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
