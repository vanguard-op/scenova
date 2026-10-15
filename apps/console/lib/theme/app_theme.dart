import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

/// Builds the console's [ThemeData] from the design system's tokens.
///
/// The console is the branding doc's Desktop device class ("Responsive &
/// Device Targets": pointer and keyboard, the operator console), so the
/// device-keyed scales are the Desktop column. The shared base carries the
/// palette, the type scale, and the layout tokens; the console adds the pieces
/// its own chrome uses — dense inputs, tooltips, and its dropdown menu.
///
/// Every screen consumes the theme and the token extensions; nothing in the
/// presentation layer names a colour, size, radius, or duration directly.
abstract final class AppTheme {
  static ThemeData build({required Brightness brightness}) {
    return ScenovaTheme.build(
      brightness: brightness,
      deviceClass: DeviceClass.desktop,
      denseInputs: true,
      tooltip: true,
      dropdownMenu: true,
    );
  }
}
