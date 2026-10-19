import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';

/// Every icon the product draws, resolved to the platform's standard icon pack.
///
/// Both apps bundle Material Icons (`uses-material-design: true`), so a product
/// action and a piece of app chrome come from one pack, drawn at one grid and
/// scaled by the size tokens. The names below are the product's vocabulary for
/// the pack, so a screen asks for [seeIt] or [report] rather than a raw
/// `IconData` and the reading of an action is decided in one place.
abstract final class AppIcons {
  // The product's own actions.
  static const IconData seeIt = Icons.visibility_outlined;
  static const IconData play = Icons.play_arrow_rounded;
  static const IconData pause = Icons.pause_rounded;
  static const IconData replay = Icons.replay_rounded;
  static const IconData listen = Icons.volume_up_rounded;
  static const IconData mute = Icons.volume_off_rounded;
  static const IconData report = Icons.flag_outlined;
  static const IconData history = Icons.history_rounded;
  static const IconData settings = Icons.settings_outlined;

  /// The overflow: the actions a card holds beyond the few it shows. The
  /// vertical dots name a menu that opens at the control itself.
  static const IconData more = Icons.more_vert_rounded;

  // Reader chrome.
  static const IconData account = Icons.person_outline_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData reading = Icons.auto_stories_outlined;
  static const IconData error = Icons.error_outline_rounded;
  static const IconData offline = Icons.cloud_off_rounded;
  static const IconData info = Icons.info_outline_rounded;
  static const IconData retry = Icons.refresh_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData remove = Icons.delete_outline_rounded;
  static const IconData helpful = Icons.thumb_up_outlined;
  static const IconData notHelpful = Icons.thumb_down_outlined;

  // Console chrome: the sidebar, the table, and the queue's states.
  static const IconData signOut = Icons.logout_rounded;
  static const IconData queue = Icons.inbox_outlined;
  static const IconData next = Icons.chevron_right_rounded;
  static const IconData previous = Icons.chevron_left_rounded;
  static const IconData expand = Icons.expand_more_rounded;
  static const IconData queued = Icons.schedule_rounded;
  static const IconData actioned = Icons.check_circle_outline_rounded;
  static const IconData refused = Icons.lock_outline_rounded;
  static const IconData filter = Icons.filter_list_rounded;
  static const IconData sortNewest = Icons.sort_rounded;

  // Console chrome: the Review Entry screen's actions and notes.
  static const IconData warning = Icons.warning_amber_rounded;
  static const IconData check = Icons.check_rounded;
}

/// Draws an icon from the platform's pack in the product's tone.
///
/// The default tone is the iconography direction's `text-secondary`
/// ([ScenovaColors.iconDefault]). An [active] control — one that is switched on,
/// or the option the reader picked — draws in the primary accent
/// ([ScenovaColors.iconActive]); a control that cannot be used draws in the
/// disabled shade ([ScenovaColors.iconDisabled]), a lower-contrast solid so the
/// muted state reads through brightness alone. When a caller needs a tone
/// outside those — the clip player's affordance on the primary accent, or a
/// status badge in its semantic family — it passes [color] and the state's tone
/// steps aside.
///
/// The icon is decorative unless [semanticLabel] is set, so it never adds a
/// second spoken label beside the text that already carries the meaning.
class AppIconView extends StatelessWidget {
  const AppIconView({
    super.key,
    required this.icon,
    this.active = false,
    this.enabled = true,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final IconData icon;

  /// Whether the control the icon belongs to is switched on or chosen.
  final bool active;

  /// Whether the control can be used; a disabled one takes the muted shade.
  final bool enabled;

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
    final tone = color ?? toneFor(colors, active: active, enabled: enabled);

    final glyph = Icon(icon, size: dimension, color: tone);

    if (semanticLabel == null) return ExcludeSemantics(child: glyph);
    return Semantics(label: semanticLabel, image: true, child: glyph);
  }

  /// The colour token an icon resolves to for its state. Exposed so a host
  /// control can match its own foreground (an ink splash, say) to the icon it
  /// draws.
  static Color toneFor(
    ScenovaColors colors, {
    required bool active,
    bool enabled = true,
  }) => !enabled
      ? colors.iconDisabled
      : active
      ? colors.iconActive
      : colors.iconDefault;
}
