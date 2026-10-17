import Flutter
import UIKit

/// The iOS side of the capture channel (`app.scenova/capture`).
///
/// The share extension runs in its own process and cannot call the app, so it
/// writes only the selected text into the shared App Group container and opens
/// the app through the `scenova://capture` URL. This bridge reads that selection
/// and hands it to Dart, where the same entry gate as the Android action trims
/// it, holds it to the six-word limit, and opens the in-context clip view.
///
/// Two arrival paths meet here: a cold start reads the pending selection when
/// Dart asks for it, and a warm app receives it over the channel as soon as the
/// URL arrives.
final class CaptureBridge {
  static let shared = CaptureBridge()

  /// The channel Dart listens on.
  static let channelName = "app.scenova/capture"

  /// The App Group both the app and the share extension write to.
  static let appGroup = "group.app.scenova.scenova"

  /// The key the share extension writes the selected text under.
  static let pendingSelectionKey = "pendingSelection"

  /// The URL the share extension opens to hand a selection over.
  static let captureURL = URL(string: "scenova://capture")!

  private static let methodCapture = "capture"
  private static let methodReady = "ready"
  private static let methodPendingSelection = "pendingSelection"

  private var channel: FlutterMethodChannel?
  private var isReady = false

  /// Held strongly: the scene life-cycle delegate registry keeps weak
  /// references.
  private var sceneDelegate: CaptureSceneDelegate?

  private init() {}

  /// Binds the bridge to the engine and registers the scene delegate that
  /// receives the capture URL.
  func attach(
    messenger: FlutterBinaryMessenger,
    pluginRegistry: FlutterPluginRegistry
  ) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel

    if sceneDelegate == nil {
      let delegate = CaptureSceneDelegate()
      sceneDelegate = delegate
      pluginRegistry.registrar(forPlugin: "ScenovaCapture")?
        .addSceneDelegate(delegate)
    }
  }

  /// Handles the capture URL. Returns whether it belonged to the capture entry
  /// point, so Flutter's own deep-link routing leaves it alone.
  ///
  /// A cold start can reach here before Dart has asked for the selection, so the
  /// value stays in the group container until `pendingSelection` reads it.
  @discardableResult
  func handle(url: URL) -> Bool {
    guard url.scheme == "scenova", url.host == "capture" else { return false }
    guard isReady, let channel, let text = takePending() else { return true }
    channel.invokeMethod(Self.methodCapture, arguments: ["text": text])
    return true
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case Self.methodPendingSelection:
      result(takePending())
    case Self.methodReady:
      isReady = true
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Reads and clears the selection the extension left, if any.
  private func takePending() -> String? {
    guard let defaults = UserDefaults(suiteName: Self.appGroup) else { return nil }
    let text = defaults.string(forKey: Self.pendingSelectionKey)
    defaults.removeObject(forKey: Self.pendingSelectionKey)
    return text
  }
}

/// Receives the capture URL through the scene life-cycle delegate Flutter vends
/// to plugins, on both the cold-start and warm paths.
final class CaptureSceneDelegate: NSObject, FlutterSceneLifeCycleDelegate {

  // `UIScene.ConnectionOptions`, not the top-level `UISceneConnectionOptions`:
  // the latter was renamed in the newer iOS SDK and the compiler rejects it.
  @objc func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let urlContexts = connectionOptions?.urlContexts else { return false }
    return handle(urlContexts)
  }

  @objc func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) -> Bool {
    return handle(URLContexts)
  }

  private func handle(_ urlContexts: Set<UIOpenURLContext>) -> Bool {
    var handled = false
    for context in urlContexts {
      if CaptureBridge.shared.handle(url: context.url) {
        handled = true
      }
    }
    return handled
  }
}
