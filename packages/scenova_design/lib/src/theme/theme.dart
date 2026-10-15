import 'package:flutter/material.dart';

import 'colors.dart';
import 'tokens.dart';
import 'typography.dart';

/// Builds a [ThemeData] from the design system's token files.
///
/// Both apps consume the theme and the token extensions; nothing in their
/// presentation layers names a colour, size, radius, or duration directly.
///
/// The switches below carry the few pieces each app adds to the shared base —
/// the reader app's bottom sheet and list rows, the console's dense inputs and
/// its menu chrome — so the base theme has one source rather than a copy per
/// app.
abstract final class ScenovaTheme {
  static ThemeData build({
    required Brightness brightness,
    required DeviceClass deviceClass,
    bool denseInputs = false,
    bool brandFocusColor = false,
    bool bottomSheet = false,
    bool listTile = false,
    bool tooltip = false,
    bool dropdownMenu = false,
  }) {
    final colors = ScenovaColors.resolve(brightness);
    final typeScale = ScenovaTypeScale.of(deviceClass);
    final textStyles = ScenovaTextStyles.resolve(typeScale);
    final tokens = ScenovaTokens.resolve(
      deviceClass: deviceClass,
      brightness: brightness,
    );
    final scheme = colors.toColorScheme(brightness);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.surface,
      canvasColor: colors.surface,
      splashFactory: InkSparkle.splashFactory,
      extensions: <ThemeExtension<dynamic>>[colors, textStyles, tokens],
      textTheme: textStyles.toTextTheme(),
      iconTheme: IconThemeData(color: colors.iconDefault),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
        space: tokens.spacing.lg,
      ),
      // The reader app tints the platform's own focus fill with the brand
      // colour; the console leaves it at its default subtle tint, because its
      // controls draw the brand's own ring and a full element-colour fill
      // would wash out the text it lands on.
      focusColor: brandFocusColor ? colors.focusRing : null,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textStyles.h2.copyWith(color: colors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceSecondary,
        isDense: denseInputs,
        contentPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.md,
          vertical: denseInputs ? tokens.spacing.sm : tokens.spacing.md,
        ),
        hintStyle: textStyles.body.copyWith(color: colors.placeholder),
        errorStyle: textStyles.caption.copyWith(color: colors.error.element),
        helperStyle: textStyles.caption.copyWith(color: colors.textSecondary),
        border: _inputBorder(colors.border, 1),
        enabledBorder: _inputBorder(colors.border, 1),
        focusedBorder: _inputBorder(colors.focusRing, 2),
        errorBorder: _inputBorder(colors.error.element, 1),
        focusedErrorBorder: _inputBorder(colors.error.element, 2),
        disabledBorder: _inputBorder(colors.border, 1),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primary,
        linearTrackColor: colors.primaryTint,
        circularTrackColor: colors.primaryTint,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.textPrimary,
        contentTextStyle: textStyles.bodySmall.copyWith(color: colors.surface),
        actionTextColor: colors.primaryTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
        ),
        elevation: 0,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ScenovaRadius.lg),
        ),
        titleTextStyle: textStyles.h3.copyWith(color: colors.textPrimary),
        contentTextStyle: textStyles.body.copyWith(color: colors.textSecondary),
      ),
      bottomSheetTheme: bottomSheet
          ? BottomSheetThemeData(
              backgroundColor: colors.surface,
              surfaceTintColor: Colors.transparent,
              showDragHandle: true,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(ScenovaRadius.lg),
                ),
              ),
            )
          : null,
      listTileTheme: listTile
          ? ListTileThemeData(
              iconColor: colors.iconDefault,
              textColor: colors.textPrimary,
              contentPadding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.md,
              ),
              minVerticalPadding: tokens.spacing.sm,
            )
          : null,
      tooltipTheme: tooltip
          ? TooltipThemeData(
              decoration: BoxDecoration(
                color: colors.textPrimary,
                borderRadius: BorderRadius.circular(ScenovaRadius.sm),
              ),
              textStyle: textStyles.caption.copyWith(color: colors.surface),
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.sm,
                vertical: tokens.spacing.xs,
              ),
            )
          : null,
      dropdownMenuTheme: dropdownMenu
          ? DropdownMenuThemeData(
              menuStyle: MenuStyle(
                backgroundColor: WidgetStatePropertyAll<Color>(colors.surface),
                surfaceTintColor: const WidgetStatePropertyAll<Color>(
                  Colors.transparent,
                ),
                shape: WidgetStatePropertyAll<OutlinedBorder>(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ScenovaRadius.md),
                    side: BorderSide(color: colors.border),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  static OutlineInputBorder _inputBorder(Color color, double width) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(ScenovaRadius.md),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
