import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'focus_ring.dart';

/// The action variants from `docs/Scenova/branding.md` → "Component Tokens →
/// Buttons".
enum ScenovaButtonVariant { primary, secondary, outline, ghost, destructive }

/// A labelled action.
///
/// The component tokens fix the background, text, border, radius, height, and
/// padding per variant; pressed states move to the adjacent darker shade and
/// disabled states drop to the variant's own family's tinted shade. A focused
/// control draws the brand focus ring, and its height is the token scale's
/// control height for the device class, so a reader's control meets the 44px
/// minimum touch target and the console's stays above the 24px minimum pointer
/// target.
class ScenovaButton extends StatefulWidget {
  const ScenovaButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = ScenovaButtonVariant.primary,
    this.icon,
    this.semanticLabel,
    this.expanded = false,
    this.isSubmitting = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final ScenovaButtonVariant variant;
  final AppIcon? icon;
  final String? semanticLabel;
  final bool expanded;
  final bool isSubmitting;

  @override
  State<ScenovaButton> createState() => _ScenovaButtonState();
}

class _ScenovaButtonState extends State<ScenovaButton> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final enabled = widget.onPressed != null && !widget.isSubmitting;
    final palette = _VariantPalette.resolve(
      variant: widget.variant,
      colors: colors,
      enabled: enabled,
    );

    final content = <Widget>[
      if (widget.isSubmitting)
        SizedBox.square(
          dimension: tokens.sizing.iconSm,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: palette.foreground,
          ),
        )
      else if (widget.icon != null)
        AppIconView(
          icon: widget.icon!,
          size: tokens.sizing.iconSm,
          color: palette.foreground,
        ),
      if (widget.isSubmitting || widget.icon != null)
        SizedBox(width: tokens.spacing.sm),
      Flexible(
        child: Text(
          widget.label,
          style: styles.body.copyWith(
            fontWeight: FontWeight.w600,
            color: palette.foreground,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ];

    final surface = Material(
      color: palette.background,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ScenovaRadius.md),
        side: palette.borderColor == null
            ? BorderSide.none
            : BorderSide(
                color: palette.borderColor!,
                width: palette.borderWidth,
              ),
      ),
      child: InkWell(
        focusNode: _focusNode,
        canRequestFocus: enabled,
        onFocusChange: (value) => setState(() => _focused = value),
        onTap: enabled ? widget.onPressed : null,
        focusColor: Colors.transparent,
        child: SizedBox(
          height: tokens.sizing.buttonHeight,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.lg),
            child: Row(
              mainAxisSize: widget.expanded
                  ? MainAxisSize.max
                  : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: content,
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel ?? widget.label,
      child: FocusRing(
        visible: _focused,
        radius: ScenovaRadius.md,
        child: widget.expanded
            ? SizedBox(width: double.infinity, child: surface)
            : surface,
      ),
    );
  }
}

/// A square icon action at the token scale's control height for the device
/// class.
class ScenovaIconButton extends StatefulWidget {
  const ScenovaIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
    this.semanticLabel,
  });

  final AppIcon icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// The filled/active treatment from the iconography direction.
  final bool active;
  final String? semanticLabel;

  @override
  State<ScenovaIconButton> createState() => _ScenovaIconButtonState();
}

class _ScenovaIconButtonState extends State<ScenovaIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final enabled = widget.onPressed != null;
    final state = !enabled
        ? ScenovaIconState.disabled
        : widget.active
        ? ScenovaIconState.active
        : ScenovaIconState.inactive;
    final color = AppIconView.toneFor(colors, state);

    return FocusRing(
      visible: _focused,
      radius: ScenovaRadius.md,
      // `canRequestFocus: false` keeps this node out of the traversal order
      // while still reporting when the button inside it takes focus.
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (value) => setState(() => _focused = value),
        child: IconButton(
          onPressed: widget.onPressed,
          tooltip: widget.tooltip,
          icon: AppIconView(
            icon: widget.icon,
            state: state,
            size: tokens.sizing.iconMd,
          ),
          style: IconButton.styleFrom(
            minimumSize: Size.square(tokens.sizing.buttonHeight),
            tapTargetSize: MaterialTapTargetSize.padded,
            foregroundColor: color,
          ),
        ),
      ),
    );
  }
}

/// The background, text, and border for one variant and enabled state.
class _VariantPalette {
  const _VariantPalette({
    required this.background,
    required this.foreground,
    this.borderColor,
    this.borderWidth = 0,
  });

  final Color background;
  final Color foreground;
  final Color? borderColor;
  final double borderWidth;

  static _VariantPalette resolve({
    required ScenovaButtonVariant variant,
    required ScenovaColors colors,
    required bool enabled,
  }) {
    if (!enabled) {
      return _VariantPalette(
        background: switch (variant) {
          // Each variant drops to its own family's tinted shade; a destructive
          // control keeps the error tint rather than borrowing the primary one.
          ScenovaButtonVariant.primary => colors.primaryTint,
          ScenovaButtonVariant.destructive => colors.error.tint,
          ScenovaButtonVariant.secondary => colors.surfaceSecondary,
          ScenovaButtonVariant.outline ||
          ScenovaButtonVariant.ghost => ScenovaPalette.transparent,
        },
        foreground: colors.textDisabled,
        borderColor: variant == ScenovaButtonVariant.outline
            ? colors.border
            : null,
        borderWidth: variant == ScenovaButtonVariant.outline ? 1.5 : 0,
      );
    }
    return switch (variant) {
      ScenovaButtonVariant.primary => _VariantPalette(
        background: colors.primary,
        foreground: colors.onSolid,
      ),
      ScenovaButtonVariant.secondary => _VariantPalette(
        background: colors.primaryTint,
        foreground: colors.primaryDeep,
      ),
      ScenovaButtonVariant.outline => _VariantPalette(
        background: ScenovaPalette.transparent,
        foreground: colors.primary,
        borderColor: colors.primary,
        borderWidth: 1.5,
      ),
      ScenovaButtonVariant.ghost => _VariantPalette(
        background: ScenovaPalette.transparent,
        foreground: colors.textSecondary,
      ),
      ScenovaButtonVariant.destructive => _VariantPalette(
        background: colors.error.element,
        foreground: colors.onSolid,
      ),
    };
  }
}
