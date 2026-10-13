import 'package:flutter/material.dart';

import '../models/analytics_event.dart';
import '../screens/clip_controller.dart';
import '../screens/clip_view_screen.dart';
import '../services/app_services.dart';
import '../services/capture_intake.dart';
import '../services/extension_channel.dart';
import '../theme/app_theme.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';

/// The clip view as the iOS share extension presents it (`FEAT-002`).
///
/// The share extension hosts this in its own sheet, so the clip view opens over
/// the reading app and the reader returns to their page when it is dismissed.
/// The selection arrives over the same capture channel as the Android action,
/// so the entry gate resolves it once: an empty or non-text selection starts no
/// lookup and shows the empty state, and a selection over the six-word limit is
/// held to the limit with a notice.
///
/// This runs in the extension's own process, so it wires the collaborators
/// itself rather than sharing the app's. Device history and the reader's
/// preferences arrive with their own features; the extension starts from the
/// same defaults as a fresh app.
class ClipExtensionApp extends StatefulWidget {
  const ClipExtensionApp({
    super.key,
    required this.services,
    required this.extensionChannel,
  });

  final ScenovaServices services;
  final ExtensionChannel extensionChannel;

  @override
  State<ClipExtensionApp> createState() => _ClipExtensionAppState();
}

class _ClipExtensionAppState extends State<ClipExtensionApp>
    with WidgetsBindingObserver {
  ClipViewController? _controller;
  late DeviceClass _deviceClass = _resolveDeviceClass();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncPlatformAccessibility();
    widget.services.captureChannel.selections.listen(_onSelection);
    widget.services.captureChannel.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    widget.services.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final next = _resolveDeviceClass();
    if (next != _deviceClass) setState(() => _deviceClass = next);
  }

  @override
  void didChangeAccessibilityFeatures() => _syncPlatformAccessibility();

  void _syncPlatformAccessibility() {
    widget.services.settings.platformReduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
  }

  DeviceClass _resolveDeviceClass() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return DeviceClass.fromWidth(
      view.physicalSize.width / view.devicePixelRatio,
    );
  }

  /// A selection arrived from the extension. An empty one opens the empty
  /// state; a live one reuses the open view, as the entry gate does in the app.
  void _onSelection(CaptureSelection selection) {
    final existing = _controller;
    if (existing != null) {
      existing.submit(selection);
      return;
    }
    setState(() {
      _controller = ClipViewController(
        services: widget.services,
        selection: selection,
        source: LookupSource.iosExtension,
      );
    });
  }

  /// The reader dismissed the clip view: close the extension so the reading app
  /// comes back with their place unchanged.
  Future<void> _dismiss() => widget.extensionChannel.dismiss();

  @override
  Widget build(BuildContext context) {
    return ScenovaScope(
      services: widget.services,
      child: MaterialApp(
        title: 'Scenova',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(
          brightness: Brightness.light,
          deviceClass: _deviceClass,
        ),
        darkTheme: AppTheme.build(
          brightness: Brightness.dark,
          deviceClass: _deviceClass,
        ),
        themeMode: ThemeMode.system,
        home: _body(),
      ),
    );
  }

  Widget _body() {
    final controller = _controller;
    if (controller == null) {
      // Nothing has arrived yet; the reading page stays visible.
      return const Scaffold(backgroundColor: ScenovaPalette.transparent);
    }
    return ClipViewScreen(
      key: ValueKey<ClipViewController>(controller),
      controller: controller,
      presentation: ClipPresentation.extension,
      onDismiss: _dismiss,
    );
  }
}
