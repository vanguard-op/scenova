import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../models/analytics_event.dart';
import '../services/app_services.dart';
import '../services/capture_intake.dart';
import 'clip_controller.dart';
import 'clip_view_screen.dart';

/// The clip view as the Android selection action shows it (`FEAT-001`,
/// `FEAT-008`).
///
/// A reader who chooses the Scenova entry in a reading app's selection menu gets
/// the clip in place: the card over their page, never the app's own Home behind
/// it and no route to it. Dismissing closes the activity, so the reading app
/// comes back with the reader's place unchanged — the same shape as the iOS
/// share extension, hosted by the Android activity instead of a sheet.
///
/// The selection arrives over the capture channel after this surface has
/// subscribed, so a selection that landed before the Flutter UI was up still
/// opens the card. A second selection through the entry gate reuses this view
/// rather than opening a second one
/// (`docs/Scenova/user-flow.md` → "Alternate Path E").
class ClipActionScreen extends StatefulWidget {
  const ClipActionScreen({super.key, required this.services});

  final ScenovaServices services;

  @override
  State<ClipActionScreen> createState() => _ClipActionScreenState();
}

class _ClipActionScreenState extends State<ClipActionScreen> {
  ClipViewController? _controller;

  @override
  void initState() {
    super.initState();
    widget.services.captureChannel.selections.listen(_onSelection);
    // This surface owns the selection stream for the action entry, so it
    // subscribes before asking the platform for the selection that arrived
    // before the UI was up.
    widget.services.captureChannel.start();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// A selection arrived from the action. A live one reuses the open view; an
  /// empty one opens the empty state and starts no lookup.
  void _onSelection(CaptureSelection selection) {
    final existing = _controller;
    if (existing != null) {
      unawaited(existing.submit(selection));
      return;
    }
    setState(() {
      _controller = ClipViewController(
        services: widget.services,
        selection: selection,
        source: LookupSource.androidAction,
      );
    });
  }

  /// The reader closed the card: finish the activity so the reading app comes
  /// back, rather than revealing an app surface behind it.
  Future<void> _dismiss() => widget.services.captureChannel.finish();

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    // Nothing has arrived yet; the reading page stays visible rather than the
    // app's own chrome appearing behind the card.
    if (controller == null) {
      return const Scaffold(backgroundColor: ScenovaPalette.transparent);
    }
    return ClipViewScreen(
      key: ValueKey<ClipViewController>(controller),
      controller: controller,
      presentation: ClipPresentation.inPlace,
      onDismiss: _dismiss,
    );
  }
}
