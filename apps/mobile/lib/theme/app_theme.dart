import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

/// Builds the reader app's [ThemeData] from the design system's tokens.
///
/// The shared base carries the palette, the type scale, and the layout tokens;
/// the reader app adds the pieces its own surfaces use — the platform focus
/// fill in the brand colour, the bottom sheet its in-context card becomes on
/// tablet, and the list rows its History screen draws.
///
/// Every screen consumes the theme and the token extensions; nothing in the
/// presentation layer names a colour, size, radius, or duration directly.
abstract final class AppTheme {
  static ThemeData build({
    required Brightness brightness,
    required DeviceClass deviceClass,
  }) {
    return ScenovaTheme.build(
      brightness: brightness,
      deviceClass: deviceClass,
      brandFocusColor: true,
      bottomSheet: true,
      listTile: true,
    );
  }
}
