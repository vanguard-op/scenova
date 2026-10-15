import 'package:flutter/material.dart';

/// Colour tokens for Scenova.
///
/// Source of truth: `docs/Scenova/branding.md` — "Color Palette". Both apps
/// resolve every colour through the design system; no widget carries a literal
/// colour.
///
/// Each accent and semantic family publishes its full 100/300/500/700/900
/// scale: 500 is the element colour, 100 tints its background, 900 is its text,
/// and 300 and 700 are the borders and pressed states.
abstract final class ScenovaPalette {
  // Primary — a 9-shade scale.
  static const Color primary900Light = Color(0xFF221B54);
  static const Color primary900Dark = Color(0xFFDCD6FB);
  static const Color primary800Light = Color(0xFF2E2470);
  static const Color primary800Dark = Color(0xFFC7BFF7);
  static const Color primary700Light = Color(0xFF3B2E8C);
  static const Color primary700Dark = Color(0xFFB0A6F2);
  static const Color primary600Light = Color(0xFF4B3BA8);
  static const Color primary600Dark = Color(0xFF9A8EEC);
  static const Color primary500Light = Color(0xFF5C4BC4);
  static const Color primary500Dark = Color(0xFF8578E4);
  static const Color primary400Light = Color(0xFF7E70D4);
  static const Color primary400Dark = Color(0xFF6A5DCB);
  static const Color primary300Light = Color(0xFFA79CE3);
  static const Color primary300Dark = Color(0xFF5247A6);
  static const Color primary200Light = Color(0xFFCBC4F0);
  static const Color primary200Dark = Color(0xFF3C3480);
  static const Color primary100Light = Color(0xFFEEEBFA);
  static const Color primary100Dark = Color(0xFF262151);

  // Neutral — grey 900 to 50.
  static const Color grey900Light = Color(0xFF1A1820);
  static const Color grey900Dark = Color(0xFFF4F3F7);
  static const Color grey800Light = Color(0xFF2A2733);
  static const Color grey800Dark = Color(0xFFE3E1E9);
  static const Color grey700Light = Color(0xFF3A3745);
  static const Color grey700Dark = Color(0xFFC9C6D2);
  static const Color grey600Light = Color(0xFF504C5C);
  static const Color grey600Dark = Color(0xFFA7A3B2);
  static const Color grey500Light = Color(0xFF6B6775);
  static const Color grey500Dark = Color(0xFF85808F);
  static const Color grey400Light = Color(0xFF8C8896);
  static const Color grey400Dark = Color(0xFF625E6C);
  static const Color grey300Light = Color(0xFFB6B3BE);
  static const Color grey300Dark = Color(0xFF47434F);
  static const Color grey200Light = Color(0xFFD6D4DB);
  static const Color grey200Dark = Color(0xFF33303A);
  static const Color grey100Light = Color(0xFFECEBEF);
  static const Color grey100Dark = Color(0xFF26242C);
  static const Color grey50Light = Color(0xFFF7F6F9);
  static const Color grey50Dark = Color(0xFF1B1A20);

  // Success — a resolved lookup or a saved clip.
  static const Color success100Light = Color(0xFFEEF7F3);
  static const Color success100Dark = Color(0xFF114029);
  static const Color success300Light = Color(0xFF96D9BB);
  static const Color success300Dark = Color(0xFF2E8A5B);
  static const Color success500Light = Color(0xFF2E9E6B);
  static const Color success500Dark = Color(0xFF57C48D);
  static const Color success700Light = Color(0xFF1F7F53);
  static const Color success700Dark = Color(0xFF9CD3B7);
  static const Color success900Light = Color(0xFF105133);
  static const Color success900Dark = Color(0xFFCFE7DB);

  // Warning — a slow lookup or a still-generating clip.
  static const Color warning100Light = Color(0xFFFAF0EB);
  static const Color warning100Dark = Color(0xFF4A2008);
  static const Color warning300Light = Color(0xFFE8A787);
  static const Color warning300Dark = Color(0xFF9E4A19);
  static const Color warning500Light = Color(0xFFC9541B);
  static const Color warning500Dark = Color(0xFFDE7B42);
  static const Color warning700Light = Color(0xFF90390E);
  static const Color warning700Dark = Color(0xFFE3AC8D);
  static const Color warning900Light = Color(0xFF5B2206);
  static const Color warning900Dark = Color(0xFFEFD6C7);

  // Error — a failed generation or a destructive action.
  static const Color error100Light = Color(0xFFF7EEEE);
  static const Color error100Dark = Color(0xFF470B0B);
  static const Color error300Light = Color(0xFFD89797);
  static const Color error300Dark = Color(0xFF981F1F);
  static const Color error500Light = Color(0xFFC43B3B);
  static const Color error500Dark = Color(0xFFDE6A6A);
  static const Color error700Light = Color(0xFF7E2020);
  static const Color error700Dark = Color(0xFFDE9191);
  static const Color error900Light = Color(0xFF501111);
  static const Color error900Dark = Color(0xFFEDCACA);

  // Info — an informational note or tip.
  static const Color info100Light = Color(0xFFECF1F9);
  static const Color info100Dark = Color(0xFF07244B);
  static const Color info300Light = Color(0xFF8DB0E2);
  static const Color info300Dark = Color(0xFF1751A1);
  static const Color info500Light = Color(0xFF3C7DD9);
  static const Color info500Dark = Color(0xFF6BA0E8);
  static const Color info700Light = Color(0xFF154589);
  static const Color info700Dark = Color(0xFF8BB1E5);
  static const Color info900Light = Color(0xFF0A2A57);
  static const Color info900Dark = Color(0xFFC6D8F0);

  // Accent — the target word highlighted.
  static const Color accent100Light = Color(0xFFF8F4ED);
  static const Color accent100Dark = Color(0xFF4A3708);
  static const Color accent300Light = Color(0xFFDFC791);
  static const Color accent300Dark = Color(0xFF9F7A18);
  static const Color accent500Light = Color(0xFFC99A2E);
  static const Color accent500Dark = Color(0xFFE4BE5C);
  static const Color accent700Light = Color(0xFF856419);
  static const Color accent700Dark = Color(0xFFE4CB8C);
  static const Color accent900Light = Color(0xFF553F0C);
  static const Color accent900Dark = Color(0xFFF0E4C7);

  /// White, used for text on filled primary and destructive surfaces.
  static const Color onFill = Color(0xFFFFFFFF);

  /// No colour; used for outline and ghost surfaces.
  static const Color transparent = Color(0x00000000);
}

/// One accent or semantic family resolved for a brightness.
///
/// The 500 shade is the element colour, 100 tints its background, 900 is its
/// text, and 300 and 700 are the border and pressed shades.
@immutable
class ScenovaSemanticColors {
  const ScenovaSemanticColors({
    required this.element,
    required this.tint,
    required this.border,
    required this.pressed,
    required this.text,
  });

  final Color element;
  final Color tint;
  final Color border;
  final Color pressed;
  final Color text;
}

/// Semantic colour tokens resolved for one brightness.
///
/// Read it with [ScenovaColors.of].
@immutable
class ScenovaColors extends ThemeExtension<ScenovaColors> {
  const ScenovaColors({
    required this.surface,
    required this.surfaceSecondary,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.placeholder,
    required this.border,
    required this.iconDefault,
    required this.iconActive,
    required this.iconDisabled,
    required this.primary,
    required this.onPrimary,
    required this.primaryTint,
    required this.primaryDeep,
    required this.primaryPressed,
    required this.focusRing,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.accent,
    required this.onFill,
  });

  final Color surface;
  final Color surfaceSecondary;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color placeholder;
  final Color border;
  final Color iconDefault;
  final Color iconActive;
  final Color iconDisabled;
  final Color primary;
  final Color onPrimary;
  final Color primaryTint;
  final Color primaryDeep;
  final Color primaryPressed;
  final Color focusRing;

  /// The resolved success family: a clip saved or a lookup resolved.
  final ScenovaSemanticColors success;

  /// The resolved warning family: a slow lookup or a clip still generating.
  final ScenovaSemanticColors warning;

  /// The resolved error family: a failed generation or a destructive action.
  final ScenovaSemanticColors error;

  /// The resolved info family: an informational note or tip.
  final ScenovaSemanticColors info;

  /// The resolved accent family: the target word highlighted.
  final ScenovaSemanticColors accent;

  final Color onFill;

  static const ScenovaColors light = ScenovaColors(
    surface: ScenovaPalette.grey50Light,
    surfaceSecondary: ScenovaPalette.grey100Light,
    textPrimary: ScenovaPalette.grey900Light,
    textSecondary: ScenovaPalette.grey600Light,
    textDisabled: ScenovaPalette.grey500Light,
    // The neutral scale puts placeholder text in `grey-600`, the same shade as
    // secondary text; `grey-400` is the disabled-icon role and reads below the
    // contrast target on the input surface.
    placeholder: ScenovaPalette.grey600Light,
    border: ScenovaPalette.grey300Light,
    // The iconography direction puts the default state in `text-secondary`.
    iconDefault: ScenovaPalette.grey600Light,
    iconActive: ScenovaPalette.primary500Light,
    iconDisabled: ScenovaPalette.grey400Light,
    primary: ScenovaPalette.primary500Light,
    onPrimary: ScenovaPalette.onFill,
    primaryTint: ScenovaPalette.primary100Light,
    primaryDeep: ScenovaPalette.primary700Light,
    primaryPressed: ScenovaPalette.primary600Light,
    focusRing: ScenovaPalette.primary500Light,
    success: ScenovaSemanticColors(
      element: ScenovaPalette.success500Light,
      tint: ScenovaPalette.success100Light,
      border: ScenovaPalette.success300Light,
      pressed: ScenovaPalette.success700Light,
      text: ScenovaPalette.success900Light,
    ),
    warning: ScenovaSemanticColors(
      element: ScenovaPalette.warning500Light,
      tint: ScenovaPalette.warning100Light,
      border: ScenovaPalette.warning300Light,
      pressed: ScenovaPalette.warning700Light,
      text: ScenovaPalette.warning900Light,
    ),
    error: ScenovaSemanticColors(
      element: ScenovaPalette.error500Light,
      tint: ScenovaPalette.error100Light,
      border: ScenovaPalette.error300Light,
      pressed: ScenovaPalette.error700Light,
      text: ScenovaPalette.error900Light,
    ),
    info: ScenovaSemanticColors(
      element: ScenovaPalette.info500Light,
      tint: ScenovaPalette.info100Light,
      border: ScenovaPalette.info300Light,
      pressed: ScenovaPalette.info700Light,
      text: ScenovaPalette.info900Light,
    ),
    accent: ScenovaSemanticColors(
      element: ScenovaPalette.accent500Light,
      tint: ScenovaPalette.accent100Light,
      border: ScenovaPalette.accent300Light,
      pressed: ScenovaPalette.accent700Light,
      text: ScenovaPalette.accent900Light,
    ),
    onFill: ScenovaPalette.onFill,
  );

  static const ScenovaColors dark = ScenovaColors(
    surface: ScenovaPalette.grey50Dark,
    surfaceSecondary: ScenovaPalette.grey100Dark,
    textPrimary: ScenovaPalette.grey900Dark,
    textSecondary: ScenovaPalette.grey600Dark,
    textDisabled: ScenovaPalette.grey500Dark,
    placeholder: ScenovaPalette.grey600Dark,
    border: ScenovaPalette.grey300Dark,
    iconDefault: ScenovaPalette.grey600Dark,
    iconActive: ScenovaPalette.primary500Dark,
    iconDisabled: ScenovaPalette.grey400Dark,
    primary: ScenovaPalette.primary500Dark,
    onPrimary: ScenovaPalette.grey50Dark,
    primaryTint: ScenovaPalette.primary100Dark,
    primaryDeep: ScenovaPalette.primary700Dark,
    primaryPressed: ScenovaPalette.primary600Dark,
    focusRing: ScenovaPalette.primary500Dark,
    success: ScenovaSemanticColors(
      element: ScenovaPalette.success500Dark,
      tint: ScenovaPalette.success100Dark,
      border: ScenovaPalette.success300Dark,
      pressed: ScenovaPalette.success700Dark,
      text: ScenovaPalette.success900Dark,
    ),
    warning: ScenovaSemanticColors(
      element: ScenovaPalette.warning500Dark,
      tint: ScenovaPalette.warning100Dark,
      border: ScenovaPalette.warning300Dark,
      pressed: ScenovaPalette.warning700Dark,
      text: ScenovaPalette.warning900Dark,
    ),
    error: ScenovaSemanticColors(
      element: ScenovaPalette.error500Dark,
      tint: ScenovaPalette.error100Dark,
      border: ScenovaPalette.error300Dark,
      pressed: ScenovaPalette.error700Dark,
      text: ScenovaPalette.error900Dark,
    ),
    info: ScenovaSemanticColors(
      element: ScenovaPalette.info500Dark,
      tint: ScenovaPalette.info100Dark,
      border: ScenovaPalette.info300Dark,
      pressed: ScenovaPalette.info700Dark,
      text: ScenovaPalette.info900Dark,
    ),
    accent: ScenovaSemanticColors(
      element: ScenovaPalette.accent500Dark,
      tint: ScenovaPalette.accent100Dark,
      border: ScenovaPalette.accent300Dark,
      pressed: ScenovaPalette.accent700Dark,
      text: ScenovaPalette.accent900Dark,
    ),
    onFill: ScenovaPalette.onFill,
  );

  static ScenovaColors of(BuildContext context) {
    final colors = Theme.of(context).extension<ScenovaColors>();
    assert(colors != null, 'ScenovaColors is missing from the active theme.');
    return colors!;
  }

  static ScenovaColors resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The Material [ColorScheme] the palette maps onto, so stock widgets
  /// (dialogs, snack bars, progress indicators) inherit the brand.
  ColorScheme toColorScheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    );
    return base.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryTint,
      onPrimaryContainer: primaryDeep,
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: surfaceSecondary,
      onSurfaceVariant: textSecondary,
      outline: border,
      outlineVariant: border,
      error: error.element,
      onError: onFill,
      errorContainer: error.tint,
      onErrorContainer: error.text,
    );
  }

  @override
  ScenovaColors copyWith({
    Color? surface,
    Color? surfaceSecondary,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? placeholder,
    Color? border,
    Color? iconDefault,
    Color? iconActive,
    Color? iconDisabled,
    Color? primary,
    Color? onPrimary,
    Color? primaryTint,
    Color? primaryDeep,
    Color? primaryPressed,
    Color? focusRing,
    ScenovaSemanticColors? success,
    ScenovaSemanticColors? warning,
    ScenovaSemanticColors? error,
    ScenovaSemanticColors? info,
    ScenovaSemanticColors? accent,
    Color? onFill,
  }) {
    return ScenovaColors(
      surface: surface ?? this.surface,
      surfaceSecondary: surfaceSecondary ?? this.surfaceSecondary,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      placeholder: placeholder ?? this.placeholder,
      border: border ?? this.border,
      iconDefault: iconDefault ?? this.iconDefault,
      iconActive: iconActive ?? this.iconActive,
      iconDisabled: iconDisabled ?? this.iconDisabled,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primaryTint: primaryTint ?? this.primaryTint,
      primaryDeep: primaryDeep ?? this.primaryDeep,
      primaryPressed: primaryPressed ?? this.primaryPressed,
      focusRing: focusRing ?? this.focusRing,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      info: info ?? this.info,
      accent: accent ?? this.accent,
      onFill: onFill ?? this.onFill,
    );
  }

  @override
  ScenovaColors lerp(ThemeExtension<ScenovaColors>? other, double t) {
    if (other is! ScenovaColors) return this;
    return t < 0.5 ? this : other;
  }
}
