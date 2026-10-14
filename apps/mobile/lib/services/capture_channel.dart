import 'dart:async';

import 'package:flutter/services.dart';

import 'capture_intake.dart';

/// Where a process was entered from, so the shell opens the right surface.
///
/// On Android the same process serves a reader who opened Scenova directly and
/// one who chose the selection action from a reading app; the two must present
/// differently — the app shows Home, the action shows the clip in place over the
/// reading app and closes straight back to it.
enum CaptureEntryPoint {
  /// The reader opened Scenova itself, or a word was typed or pasted.
  app('app'),

  /// A reading app's text-selection action launched the process.
  selectionAction('selectionAction');

  const CaptureEntryPoint(this.wire);

  final String wire;

  static CaptureEntryPoint fromWire(Object? value) =>
      value == selectionAction.wire ? selectionAction : app;
}

/// The bridge from a platform entry point to the in-context clip view.
///
/// On Android the app registers as a text-selection action; on iOS it is a
/// share extension. Both hand the selected text to the same channel, so the
/// Dart side resolves the selection once ([CaptureSelection.parse]) and the
/// entry gate behaves identically on each platform.
class CaptureChannel {
  CaptureChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'app.scenova/capture';

  /// Native to Dart: a selection arrived. Argument: `{ "text": String? }`.
  static const String methodCapture = 'capture';

  /// Dart to native: the UI is ready to receive selections.
  static const String methodReady = 'ready';

  /// Dart to native: read a selection that arrived before the UI was ready.
  static const String methodPendingSelection = 'pendingSelection';

  /// Dart to native: which entry point launched this process.
  static const String methodEntryPoint = 'entryPoint';

  /// Dart to native: the reader is done with the in-place clip view, so the
  /// activity closes and the reading app comes back.
  static const String methodDismiss = 'dismiss';

  final MethodChannel _channel;
  final StreamController<CaptureSelection> _controller =
      StreamController<CaptureSelection>.broadcast();

  bool _started = false;

  /// Selections as they arrive, already normalised.
  Stream<CaptureSelection> get selections => _controller.stream;

  /// Which entry point launched this process, read before the first frame so
  /// the shell does not flash Home before the in-place clip view.
  ///
  /// A platform with no entry point (the iOS extension's own process, web, or
  /// desktop) is the app entry point.
  Future<CaptureEntryPoint> entryPoint() async {
    try {
      final value = await _channel.invokeMethod<String>(methodEntryPoint);
      return CaptureEntryPoint.fromWire(value);
    } on MissingPluginException {
      return CaptureEntryPoint.app;
    } on PlatformException {
      return CaptureEntryPoint.app;
    }
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler(_handle);

    // A selection can arrive before the Flutter UI is up; ask for it, then tell
    // the platform it can send more.
    try {
      final pending = await _channel.invokeMethod<String>(
        methodPendingSelection,
      );
      if (pending != null) {
        _controller.add(CaptureSelection.parse(pending));
      }
      await _channel.invokeMethod<void>(methodReady);
    } on MissingPluginException {
      // No platform entry point (web or desktop); selections arrive through the
      // entry field instead.
    } on PlatformException {
      // The entry point is not available on this build; the reader can still
      // type or paste a word.
    }
  }

  /// Asks the platform to close the in-place clip view, returning the reader to
  /// the reading app with their place unchanged.
  Future<void> finish() async {
    try {
      await _channel.invokeMethod<void>(methodDismiss);
    } on MissingPluginException {
      // No host: the clip view is the app's own page.
    } on PlatformException {
      // The activity is already closing.
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != methodCapture) return;
    final arguments = call.arguments;
    final text = switch (arguments) {
      Map<Object?, Object?> map => map['text'] as String?,
      String value => value,
      _ => null,
    };
    _controller.add(CaptureSelection.parse(text));
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller.close();
  }
}
