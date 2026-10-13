import 'dart:async';

import 'package:flutter/services.dart';

import 'capture_intake.dart';

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

  final MethodChannel _channel;
  final StreamController<CaptureSelection> _controller =
      StreamController<CaptureSelection>.broadcast();

  bool _started = false;

  /// Selections as they arrive, already normalised.
  Stream<CaptureSelection> get selections => _controller.stream;

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
