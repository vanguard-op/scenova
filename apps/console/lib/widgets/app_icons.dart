import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';

/// The nine glyphs of the product's custom icon set.
///
/// Source: `docs/Scenova/branding.md` → "Asset Style Guide → Iconography
/// Direction": a custom set limited to the product's actions, drawn on a 24px
/// grid with a uniform 2px stroke, round caps and joins, and a 2px corner
/// softened to match the mark. Each glyph is one idea.
enum ScenovaGlyph {
  seeIt('eye'),
  play('play'),
  pause('pause'),
  replay('replay'),
  listen('listen'),
  save('save'),
  report('report'),
  history('history'),
  settings('settings');

  const ScenovaGlyph(this.assetName);

  /// The glyph's file name under the icon set's variant directories.
  final String assetName;

  /// The set's asset path for this glyph in [state].
  ///
  /// The active state uses the filled form; the default and disabled states
  /// share the outlined form, since the disabled treatment is a tone change,
  /// not a different shape.
  String assetPath(ScenovaIconState state) {
    final variant = state == ScenovaIconState.active ? 'filled' : 'outlined';
    return 'assets/icons/$variant/$assetName.svg';
  }
}

/// The states the iconography direction gives a glyph.
///
/// The default reads in `text-secondary`, the active state in `primary-500`,
/// and the disabled state in a solid `grey-400` — brightness alone carries the
/// muted state, never opacity or alpha.
enum ScenovaIconState { inactive, active, disabled }

/// One icon: a glyph from the custom set, or a system icon for chrome the set
/// does not cover.
///
/// The custom set is deliberately limited to the product's nine actions, so
/// chrome such as search, close, or the error mark resolves to a platform icon.
sealed class AppIcon {
  const AppIcon();
}

/// A glyph drawn from the custom set.
final class GlyphIcon extends AppIcon {
  const GlyphIcon(this.glyph);

  final ScenovaGlyph glyph;
}

/// A platform icon, for chrome outside the custom set.
final class SystemIcon extends AppIcon {
  const SystemIcon(this.data);

  final IconData data;
}

/// Every icon the app draws.
///
/// The custom set resolves through the glyph branch; everything else is
/// platform chrome. Both branches render through [AppIconView], so an icon is
/// never a bare `Icon` at a call site.
abstract final class AppIcons {
  // The custom set.
  static const AppIcon seeIt = GlyphIcon(ScenovaGlyph.seeIt);
  static const AppIcon play = GlyphIcon(ScenovaGlyph.play);
  static const AppIcon pause = GlyphIcon(ScenovaGlyph.pause);
  static const AppIcon replay = GlyphIcon(ScenovaGlyph.replay);
  static const AppIcon listen = GlyphIcon(ScenovaGlyph.listen);
  static const AppIcon save = GlyphIcon(ScenovaGlyph.save);
  static const AppIcon report = GlyphIcon(ScenovaGlyph.report);
  static const AppIcon history = GlyphIcon(ScenovaGlyph.history);
  static const AppIcon settings = GlyphIcon(ScenovaGlyph.settings);

  // Platform chrome, outside the custom set's nine actions.
  static const AppIcon account = SystemIcon(Icons.person_outline_rounded);
  static const AppIcon search = SystemIcon(Icons.search_rounded);
  static const AppIcon reading = SystemIcon(Icons.auto_stories_outlined);
  static const AppIcon error = SystemIcon(Icons.error_outline_rounded);
  static const AppIcon offline = SystemIcon(Icons.cloud_off_rounded);
  static const AppIcon info = SystemIcon(Icons.info_outline_rounded);
  static const AppIcon retry = SystemIcon(Icons.refresh_rounded);
  static const AppIcon close = SystemIcon(Icons.close_rounded);
  static const AppIcon remove = SystemIcon(Icons.delete_outline_rounded);
  static const AppIcon helpful = SystemIcon(Icons.thumb_up_outlined);
  static const AppIcon notHelpful = SystemIcon(Icons.thumb_down_outlined);
  static const AppIcon wrong = SystemIcon(Icons.flag_outlined);

  // Console chrome: the sidebar, the table, and the queue's states.
  static const AppIcon signOut = SystemIcon(Icons.logout_rounded);
  static const AppIcon queue = SystemIcon(Icons.inbox_outlined);
  static const AppIcon next = SystemIcon(Icons.chevron_right_rounded);
  static const AppIcon previous = SystemIcon(Icons.chevron_left_rounded);
  static const AppIcon expand = SystemIcon(Icons.expand_more_rounded);
  static const AppIcon queued = SystemIcon(Icons.schedule_rounded);
  static const AppIcon actioned = SystemIcon(
    Icons.check_circle_outline_rounded,
  );
  static const AppIcon refused = SystemIcon(Icons.lock_outline_rounded);
  static const AppIcon filter = SystemIcon(Icons.filter_list_rounded);
  static const AppIcon sortNewest = SystemIcon(Icons.sort_rounded);

  // Console chrome: the Review Entry screen's actions and notes.
  static const AppIcon warning = SystemIcon(Icons.warning_amber_rounded);
  static const AppIcon check = SystemIcon(Icons.check_rounded);
}

/// Draws an [AppIcon] at one of the iconography direction's three states.
///
/// A glyph's tone resolves from the colour tokens for its state, so it holds on
/// light and dark. When a caller needs a tone outside the three states — the
/// clip player's play affordance on the primary accent, say — it passes
/// [color] and the state's tone steps aside.
///
/// The icon is decorative unless [semanticLabel] is set, so it never adds a
/// second spoken label beside the text that already carries the meaning.
class AppIconView extends StatelessWidget {
  const AppIconView({
    super.key,
    required this.icon,
    this.state = ScenovaIconState.inactive,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final AppIcon icon;
  final ScenovaIconState state;

  /// Defaults to the navigation and button icon size for the device class.
  final double? size;

  /// Overrides the state's token tone.
  final Color? color;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final dimension = size ?? tokens.sizing.iconMd;
    final tone = color ?? toneFor(colors, state);

    final Widget glyph = switch (icon) {
      GlyphIcon(:final glyph) => SvgPicture.asset(
        glyph.assetPath(state),
        width: dimension,
        height: dimension,
        // The set ships one tone per variant; retinting it keeps the glyph on
        // the resolved token rather than the asset's baked-in light value, so
        // the dark theme and any contextual tone are honoured.
        colorFilter: ColorFilter.mode(tone, BlendMode.srcIn),
      ),
      SystemIcon(:final data) => Icon(data, size: dimension, color: tone),
    };

    if (semanticLabel == null) return ExcludeSemantics(child: glyph);
    return Semantics(label: semanticLabel, image: true, child: glyph);
  }

  /// The colour token a state resolves to. Exposed so a host control can match
  /// its own foreground (an ink splash, say) to the icon it draws.
  static Color toneFor(ScenovaColors colors, ScenovaIconState state) =>
      switch (state) {
        ScenovaIconState.inactive => colors.iconDefault,
        ScenovaIconState.active => colors.iconActive,
        ScenovaIconState.disabled => colors.iconDisabled,
      };
}
