import 'package:flutter/material.dart';

/// Spacing, sizing, radius, shadow, and motion tokens.
///
/// Source of truth: `docs/Scenova/branding.md` — "Spacing", "Sizing",
/// "Shadows", and "Motion Direction". Values keyed by device class resolve
/// through [DeviceClass]; the mobile values are the base and the tablet class
/// overrides them at the 600px breakpoint.
///
/// Every layout value in the app resolves through this file. No widget carries
/// a literal spacing, radius, size, shadow, or duration.

/// The device class a layout is resolved for.
///
/// `docs/Scenova/branding.md` → "Responsive & Device Targets": mobile below
/// 600px, tablet at 600px and above.
enum DeviceClass {
  mobile,
  tablet;

  /// The breakpoint where the in-context card switches from a bottom sheet to
  /// a centered card.
  static const double breakpoint = 600;

  static DeviceClass fromWidth(double width) =>
      width >= breakpoint ? DeviceClass.tablet : DeviceClass.mobile;

  bool get isTablet => this == DeviceClass.tablet;
}

/// Space scale (branding → "Spacing").
@immutable
class ScenovaSpacing {
  const ScenovaSpacing({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.xxl,
    required this.xxxl,
  });

  /// Icon-to-label, inline badges.
  final double xs;

  /// Between related items, input inner padding.
  final double sm;

  /// Default: card padding, list item gaps.
  final double md;

  /// Between sections, card padding on tablet.
  final double lg;

  /// Breathing room around the in-context card.
  final double xl;

  /// Between unrelated sections.
  final double xxl;

  /// Layout-level separation above and below the fold.
  final double xxxl;

  static const mobile = ScenovaSpacing(
    xs: 4,
    sm: 8,
    md: 12,
    lg: 20,
    xl: 28,
    xxl: 40,
    xxxl: 56,
  );

  static const tablet = ScenovaSpacing(
    xs: 4,
    sm: 8,
    md: 16,
    lg: 24,
    xl: 32,
    xxl: 48,
    xxxl: 64,
  );

  static ScenovaSpacing of(DeviceClass device) =>
      device.isTablet ? tablet : mobile;
}

/// Sizing scale (branding → "Sizing").
@immutable
class ScenovaSizing {
  const ScenovaSizing({
    required this.buttonHeight,
    required this.inputHeight,
    required this.iconSm,
    required this.iconMd,
    required this.iconLg,
  });

  /// Minimum touch target for buttons.
  final double buttonHeight;

  /// The history search field.
  final double inputHeight;

  /// Inline icons and status indicators.
  final double iconSm;

  /// Navigation and button icons.
  final double iconMd;

  /// Feature icons and empty states.
  final double iconLg;

  static const mobile = ScenovaSizing(
    buttonHeight: 44,
    inputHeight: 48,
    iconSm: 16,
    iconMd: 24,
    iconLg: 32,
  );

  static const tablet = ScenovaSizing(
    buttonHeight: 44,
    inputHeight: 44,
    iconSm: 16,
    iconMd: 24,
    iconLg: 40,
  );

  static ScenovaSizing of(DeviceClass device) =>
      device.isTablet ? tablet : mobile;
}

/// Corner radii (branding → "Sizing", Fixed).
abstract final class ScenovaRadius {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double full = 9999;
}

/// Shadow tokens (branding → "Shadows").
///
/// The in-context card sits over content the product does not own, so it takes
/// [lg] plus a solid surface, never a translucent blur.
abstract final class ScenovaShadows {
  static const List<BoxShadow> none = <BoxShadow>[];

  static const List<BoxShadow> smLight = <BoxShadow>[
    BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> smDark = <BoxShadow>[
    BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
  ];

  static const List<BoxShadow> mdLight = <BoxShadow>[
    BoxShadow(color: Color(0x12000000), blurRadius: 6, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> mdDark = <BoxShadow>[
    BoxShadow(color: Color(0x80000000), blurRadius: 8, offset: Offset(0, 4)),
  ];

  static const List<BoxShadow> lgLight = <BoxShadow>[
    BoxShadow(color: Color(0x1A000000), blurRadius: 25, offset: Offset(0, 10)),
  ];
  static const List<BoxShadow> lgDark = <BoxShadow>[
    BoxShadow(color: Color(0xA6000000), blurRadius: 30, offset: Offset(0, 10)),
  ];

  static const List<BoxShadow> xlLight = <BoxShadow>[
    BoxShadow(color: Color(0x26000000), blurRadius: 50, offset: Offset(0, 24)),
  ];
  static const List<BoxShadow> xlDark = <BoxShadow>[
    BoxShadow(color: Color(0xB3000000), blurRadius: 60, offset: Offset(0, 24)),
  ];
}

/// Motion tokens.
///
/// `docs/Scenova/branding.md` describes the motion character ("calm and quick";
/// the clip view "settles in one movement and gets out of the way, with no
/// bounce or flourish") but does not enumerate timing values. These tokens are
/// the smallest set that expresses that character; they are reported as a gap
/// in the branding spec rather than invented per call site.
abstract final class ScenovaMotion {
  /// Press and focus feedback.
  static const Duration press = Duration(milliseconds: 120);

  /// The in-context card settling in and simple state changes.
  static const Duration settle = Duration(milliseconds: 240);

  /// Dismissals and larger transitions.
  static const Duration exit = Duration(milliseconds: 320);

  /// Calm deceleration for anything entering.
  static const Curve enter = Curves.easeOutCubic;

  /// Symmetric change for anything moving in place.
  static const Curve inPlace = Curves.easeInOutCubic;

  /// No motion; used when the platform reduce-motion setting is on.
  static const Duration none = Duration.zero;
}

/// Opacity tokens for placeholders and disabled surfaces.
abstract final class ScenovaOpacity {
  /// Disabled text and controls.
  static const double disabled = 0.5;

  /// The dimmest and brightest points of a loading placeholder.
  static const double placeholderMin = 0.4;
  static const double placeholderMax = 0.8;

  /// The placeholder's opacity when it holds still.
  static const double placeholderStill = 0.6;
}

/// The resolved token set for the current theme and device class.
///
/// Read it with [ScenovaTokens.of].
@immutable
class ScenovaTokens extends ThemeExtension<ScenovaTokens> {
  const ScenovaTokens({
    required this.deviceClass,
    required this.spacing,
    required this.sizing,
    required this.shadowSm,
    required this.shadowMd,
    required this.shadowLg,
    required this.shadowXl,
  });

  final DeviceClass deviceClass;
  final ScenovaSpacing spacing;
  final ScenovaSizing sizing;
  final List<BoxShadow> shadowSm;
  final List<BoxShadow> shadowMd;
  final List<BoxShadow> shadowLg;
  final List<BoxShadow> shadowXl;

  static ScenovaTokens resolve({
    required DeviceClass deviceClass,
    required Brightness brightness,
  }) {
    final isDark = brightness == Brightness.dark;
    return ScenovaTokens(
      deviceClass: deviceClass,
      spacing: ScenovaSpacing.of(deviceClass),
      sizing: ScenovaSizing.of(deviceClass),
      shadowSm: isDark ? ScenovaShadows.smDark : ScenovaShadows.smLight,
      shadowMd: isDark ? ScenovaShadows.mdDark : ScenovaShadows.mdLight,
      shadowLg: isDark ? ScenovaShadows.lgDark : ScenovaShadows.lgLight,
      shadowXl: isDark ? ScenovaShadows.xlDark : ScenovaShadows.xlLight,
    );
  }

  static ScenovaTokens of(BuildContext context) {
    final tokens = Theme.of(context).extension<ScenovaTokens>();
    assert(tokens != null, 'ScenovaTokens is missing from the active theme.');
    return tokens!;
  }

  @override
  ScenovaTokens copyWith({
    DeviceClass? deviceClass,
    ScenovaSpacing? spacing,
    ScenovaSizing? sizing,
    List<BoxShadow>? shadowSm,
    List<BoxShadow>? shadowMd,
    List<BoxShadow>? shadowLg,
    List<BoxShadow>? shadowXl,
  }) {
    return ScenovaTokens(
      deviceClass: deviceClass ?? this.deviceClass,
      spacing: spacing ?? this.spacing,
      sizing: sizing ?? this.sizing,
      shadowSm: shadowSm ?? this.shadowSm,
      shadowMd: shadowMd ?? this.shadowMd,
      shadowLg: shadowLg ?? this.shadowLg,
      shadowXl: shadowXl ?? this.shadowXl,
    );
  }

  @override
  ScenovaTokens lerp(ThemeExtension<ScenovaTokens>? other, double t) {
    if (other is! ScenovaTokens) return this;
    return t < 0.5 ? this : other;
  }
}
