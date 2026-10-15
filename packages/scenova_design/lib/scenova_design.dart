/// Scenova's design system.
///
/// The brand's tokens — colour, type, spacing, sizing, radius, shadow, motion,
/// and opacity — and the shared components both apps draw from them
/// (`docs/Scenova/branding.md`; `docs/Scenova/screens.md` → "Shared / Common
/// Components").
///
/// Both apps import this package rather than carrying a copy of the palette or
/// of the shared widgets, so a token change and the mark's audit are made once.
library;

export 'src/models/clip_source.dart';
export 'src/theme/colors.dart';
export 'src/theme/theme.dart';
export 'src/theme/tokens.dart';
export 'src/theme/typography.dart';
export 'src/widgets/app_icons.dart';
export 'src/widgets/brand_lockup.dart';
export 'src/widgets/brand_mark.dart';
export 'src/widgets/clip_player.dart';
export 'src/widgets/clip_still_frame.dart';
export 'src/widgets/console_shell.dart';
export 'src/widgets/focus_ring.dart';
export 'src/widgets/offline_banner.dart';
export 'src/widgets/scenova_button.dart';
export 'src/widgets/skeleton.dart';
export 'src/widgets/states.dart';
export 'src/widgets/status_badge.dart';
export 'src/widgets/word_phrase_header.dart';
