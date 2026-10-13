import 'package:flutter/material.dart';

/// The product's action icons.
///
/// `docs/Scenova/branding.md` → "Iconography Direction" specifies a custom set
/// on a 24px grid with a 2px stroke: see it, play, pause, replay, listen, save,
/// report, history, settings. The custom set's file paths are not in the asset
/// ledger yet, so Material outlined equivalents stand in; this is reported.
/// Every icon resolves through this file, so swapping in the custom set is one
/// change.
abstract final class AppIcons {
  static const IconData seeIt = Icons.visibility_outlined;
  static const IconData play = Icons.play_arrow_rounded;
  static const IconData pause = Icons.pause_rounded;
  static const IconData replay = Icons.replay_rounded;
  static const IconData listen = Icons.volume_up_outlined;
  static const IconData save = Icons.bookmark_border_rounded;
  static const IconData report = Icons.flag_outlined;
  static const IconData history = Icons.history_rounded;
  static const IconData settings = Icons.tune_rounded;
  static const IconData account = Icons.person_outline_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData reading = Icons.auto_stories_outlined;
  static const IconData error = Icons.error_outline_rounded;
  static const IconData offline = Icons.cloud_off_rounded;
  static const IconData info = Icons.info_outline_rounded;
  static const IconData retry = Icons.refresh_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData helpful = Icons.thumb_up_outlined;
  static const IconData notHelpful = Icons.thumb_down_outlined;
}
