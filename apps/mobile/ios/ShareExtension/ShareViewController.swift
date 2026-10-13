import UIKit
import UniformTypeIdentifiers

/// The iOS share extension for word capture (FEAT-002).
///
/// A reader who selects a word in a reading app and picks Scenova here gets the
/// in-context clip view. The extension is a separate process with its own memory
/// budget, so it reads only the shared text, writes it to the shared App Group
/// container, and opens the app; the app presents the clip view. Nothing else
/// from the reading page is read or forwarded.
///
/// The selection is resolved by the same entry gate as the Android action: an
/// empty or non-text selection starts no lookup, and a selection over the
/// six-word limit is held to the limit with a notice.
final class ShareViewController: UIViewController {

  private let appGroup = "group.app.scenova.scenova"
  private let pendingSelectionKey = "pendingSelection"

  /// Guards against handling the same selection more than once.
  private var hasHandled = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasHandled else { return }
    hasHandled = true
    readSelection { [weak self] text in
      guard let self else { return }
      self.store(text)
      self.openContainingApp()
    }
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

  /// Leaves the selection where the app can read it. An empty or non-text
  /// selection is stored empty, so the app opens its empty state and starts no
  /// lookup.
  private func store(_ text: String?) {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return }
    defaults.set(text ?? "", forKey: pendingSelectionKey)
  }

  /// Opens the containing app so it can show the clip view.
  private func openContainingApp() {
    guard let url = URL(string: "scenova://capture") else {
      finish()
      return
    }
    guard let context = extensionContext else {
      openViaApplication(url)
      finish()
      return
    }
    context.open(url) { [weak self] opened in
      if !opened { self?.openViaApplication(url) }
      self?.finish()
    }
  }

  /// Opens the containing app through the shared application. On iOS 18 and
  /// later `extensionContext.open` can refuse the app's own URL scheme, so this
  /// is the fallback path.
  private func openViaApplication(_ url: URL) {
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(url, options: [:], completionHandler: nil)
        return
      }
      responder = current.next
    }
  }

  /// Completes the request, which returns the reader to the reading app with
  /// their place unchanged.
  private func finish() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
