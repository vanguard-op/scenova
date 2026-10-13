import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The share extension hands the selected text to the app through the
    // `scenova://capture` URL; the bridge delivers it to Dart.
    CaptureBridge.shared.attach(
      messenger: engineBridge.applicationRegistrar.messenger(),
      pluginRegistry: engineBridge.pluginRegistry
    )
  }
}
