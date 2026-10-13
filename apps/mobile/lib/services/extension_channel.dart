import 'package:flutter/services.dart';

/// The handshake between the clip view and the iOS share extension that hosts
/// it (`FEAT-002`).
///
/// When the clip view runs inside the extension, dismissing it has to close the
/// extension sheet so the reader returns to the reading app with their place
/// unchanged. The app's own page presentation has no host, so the call is a
/// no-op there.
class ExtensionChannel {
  ExtensionChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'app.scenova/extension';

  /// Dart to native: the reader is done with the clip view.
  static const String methodDismiss = 'dismiss';

  final MethodChannel _channel;

  /// Asks the hosting extension to close, returning the reader to the reading
  /// app.
  Future<void> dismiss() async {
    try {
      await _channel.invokeMethod<void>(methodDismiss);
    } on MissingPluginException {
      // No host: the clip view is the app's own page.
    } on PlatformException {
      // The sheet is already closing.
    }
  }
}
