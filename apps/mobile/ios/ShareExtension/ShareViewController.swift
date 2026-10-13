import Flutter
import UIKit
import UniformTypeIdentifiers

/// The iOS share extension for word capture (`FEAT-002`).
///
/// A reader who selects a word in a reading app and picks Scenova gets the
/// in-context clip view here, over the reading page, and returns to their page
/// when the view is dismissed. The clip view is the app's own Flutter screen
/// (`ClipExtensionApp`), hosted in the extension's sheet, so it opens with the
/// reading page visible behind the card and shares one presentation with the
/// app.
///
/// The extension reads only the shared text — never the page — and hands it to
/// Flutter over the capture channel. The same entry gate as the Android action
/// resolves it: an empty or non-text selection starts no lookup and shows the
/// empty state, and a selection over the six-word limit is held to the limit
/// with a notice.
final class ShareViewController: UIViewController {

  /// The channel the Flutter clip view listens on for the selection.
  private static let captureChannelName = "app.scenova/capture"

  /// The channel the clip view uses to ask for the extension to close.
  private static let extensionChannelName = "app.scenova/extension"

  private static let methodCapture = "capture"
  private static let methodReady = "ready"
  private static let methodPendingSelection = "pendingSelection"
  private static let methodDismiss = "dismiss"

  private var engine: FlutterEngine?
  private var captureChannel: FlutterMethodChannel?

  /// The selection read from the share sheet, held until Flutter asks for it or
  /// is ready to receive it.
  private var pendingSelection: String?

  private var isReady = false
  private var isFinished = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    startFlutter()
    readSelection { [weak self] text in
      guard let self else { return }
      // A non-text selection is handed over empty, so no lookup starts.
      self.pendingSelection = text ?? ""
      self.deliverPendingSelection()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // The reader swiped the sheet away rather than tapping Close.
    finish()
  }

  /// Runs the clip view in this process and hosts it in the extension's sheet.
  private func startFlutter() {
    let engine = FlutterEngine(name: "scenova-clip-extension")
    engine.run(withEntrypoint: "clipExtensionMain")
    self.engine = engine

    let capture = FlutterMethodChannel(
      name: Self.captureChannelName,
      binaryMessenger: engine.binaryMessenger
    )
    capture.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case Self.methodPendingSelection:
        let selection = self.pendingSelection
        self.pendingSelection = nil
        result(selection)
      case Self.methodReady:
        self.isReady = true
        self.deliverPendingSelection()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    captureChannel = capture

    let host = FlutterMethodChannel(
      name: Self.extensionChannelName,
      binaryMessenger: engine.binaryMessenger
    )
    host.setMethodCallHandler { [weak self] call, result in
      if call.method == Self.methodDismiss {
        self?.finish()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    // The reading page shows through everywhere the card does not paint.
    flutter.view.backgroundColor = .clear
    flutter.view.isOpaque = false
    flutter.modalPresentationStyle = .overCurrentContext

    addChild(flutter)
    view.addSubview(flutter.view)
    flutter.view.frame = view.bounds
    flutter.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    flutter.didMove(toParent: self)
  }

  /// Pushes a selection that arrived before Flutter asked for it, once it is
  /// listening.
  private func deliverPendingSelection() {
    guard isReady, let channel = captureChannel, let text = pendingSelection
    else { return }
    pendingSelection = nil
    channel.invokeMethod(Self.methodCapture, arguments: ["text": text])
  }

  /// Reads only the text of the shared item, when one is offered.
  private func readSelection(completion: @escaping (String?) -> Void) {
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
          || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier)
      })
    else {
      completion(nil)
      return
    }

    let identifier = provider.hasItemConformingToTypeIdentifier(
      UTType.plainText.identifier
    )
      ? UTType.plainText.identifier
      : UTType.text.identifier

    provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
      let text: String?
      switch item {
      case let value as String:
        text = value
      case let value as NSAttributedString:
        text = value.string
      case let value as URL:
        text = value.absoluteString
      default:
        text = nil
      }
      DispatchQueue.main.async { completion(text) }
    }
  }

  /// Completes the request, which closes the sheet and returns the reader to the
  /// reading app with their place unchanged.
  private func finish() {
    guard !isFinished else { return }
    isFinished = true
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
