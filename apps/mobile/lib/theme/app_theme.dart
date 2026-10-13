import 'package:flutter/material.dart';

import 'colors.dart';
import 'tokens.dart';
import 'typography.dart';

/// Builds the app's [ThemeData] from the token files.
///
/// Every screen consumes the theme and the token extensions; nothing in the
/// presentation layer names a colour, size, radius, or duration directly.
abstract final class AppTheme {
  static ThemeData build({
    required Brightness brightness,
    required DeviceClass deviceClass,
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
      focusColor: colors.focusRing,
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
        contentPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.md,
          vertical: tokens.spacing.md,
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
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(ScenovaRadius.lg),
          ),
        ),
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
      listTileTheme: ListTileThemeData(
        iconColor: colors.iconDefault,
        textColor: colors.textPrimary,
        contentPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.md),
        minVerticalPadding: tokens.spacing.sm,
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, double width) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(ScenovaRadius.md),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
