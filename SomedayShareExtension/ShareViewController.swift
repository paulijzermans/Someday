import UIKit
import UniformTypeIdentifiers

/// The lone view controller for Someday's Share Extension.
///
/// iOS launches this when the user picks "Someday" from the share sheet
/// (in Instagram, Safari, Google Maps, etc.). We pull the shared URL out of
/// the extension context, wrap it in a `someday://import?url=…` deep link,
/// and hand it off to the main app to do the actual import via the Edge
/// Functions we already have wired up.
///
/// Keeping this controller deliberately minimal — no compose UI, no extra
/// buttons. The user shared the URL; they want it imported, not configured.
final class ShareViewController: UIViewController {

    /// Custom URL scheme registered on the main app's Info.plist.
    private let appScheme = "someday"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await handleShare() }
    }

    @MainActor
    private func handleShare() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            finish()
            return
        }

        // The share sheet may attach multiple items (URL + screenshot, e.g.).
        // We only care about URLs — first one wins.
        for attachment in item.attachments ?? [] {
            if let url = await loadURL(from: attachment) {
                openInMainApp(sharedURL: url)
                finish()
                return
            }
        }

        // No URL found (user shared something we can't import). Bail out
        // silently — the share sheet just closes from the user's POV.
        finish()
    }

    /// Try to coerce an `NSItemProvider` into a real URL. Some apps send
    /// the URL as a `url` type-identifier, some as plain text — we try both.
    private func loadURL(from attachment: NSItemProvider) async -> URL? {
        // Direct URL type.
        if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url: URL = await loadItem(attachment, type: UTType.url.identifier) as? URL {
                return url
            }
        }
        // Plain text — extract first URL with NSDataDetector.
        if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadItem(attachment, type: UTType.plainText.identifier) as? String,
               let detected = firstURL(in: text) {
                return detected
            }
        }
        return nil
    }

    /// Async wrapper around `NSItemProvider.loadItem` because the SDK
    /// version is still completion-based.
    private func loadItem(_ provider: NSItemProvider, type: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    private func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url
    }

    /// Build the `someday://import?url=…` deep link and ask iOS to open it.
    /// We can't call `UIApplication.shared.open` directly from an extension,
    /// so walk the responder chain to find the hosting `UIApplication` and
    /// call its `open(_:options:completionHandler:)` via `perform(_:with:)`.
    private func openInMainApp(sharedURL: URL) {
        // Use URLComponents so the shared URL — which itself may contain
        // `?`, `&`, `=` (e.g. tracking params from Google Maps) — gets
        // percent-encoded correctly into the query value.
        var components = URLComponents()
        components.scheme = appScheme
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: sharedURL.absoluteString)]
        guard let target = components.url else { return }

        var responder: UIResponder? = self
        while responder != nil {
            if let app = responder as? UIApplication {
                _ = app.perform(
                    #selector(UIApplication.open(_:options:completionHandler:)),
                    with: target,
                    with: nil
                )
                return
            }
            responder = responder?.next
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
