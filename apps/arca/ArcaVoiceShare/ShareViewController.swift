import UIKit
import UniformTypeIdentifiers
import ArcaVoiceKit

/// "Share to ARCA" — accepts an image, URL, or text from the iOS share sheet,
/// drops it into the shared App Group inbox, and gets out of the way instantly
/// (kip!-style): a tiny ember checkmark, then back to whatever the user was
/// doing. Also flags the app to jump straight into the "instant context"
/// screen the next time it comes forward. No network calls here — extensions
/// get a short runtime and a small memory budget, so this stays minimal.
final class ShareViewController: UIViewController {
    private let ember = UIColor(red: 1.0, green: 0.478, blue: 0.102, alpha: 1)
    private let surfaceTop = UIColor(red: 0.165, green: 0.094, blue: 0.071, alpha: 1)
    private let checkmark = UIImageView()
    private let label = UILabel()
    private let startTime = Date()
    private let minimumDisplay: TimeInterval = 0.8

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpConfirmationUI()
        handleInput()
    }

    // MARK: - Confirmation UI

    private func setUpConfirmationUI() {
        preferredContentSize = CGSize(width: 320, height: 220)
        view.backgroundColor = surfaceTop

        let config = UIImage.SymbolConfiguration(pointSize: 46, weight: .semibold)
        checkmark.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: config)
        checkmark.tintColor = ember
        checkmark.contentMode = .scaleAspectFit
        checkmark.translatesAutoresizingMaskIntoConstraints = false

        label.text = "Got it — open ARCA"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [checkmark, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Starts hidden — animated in immediately so the confirmation feels
        // instant even while the attachments are still being written to disk.
        stack.alpha = 0
        stack.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.65,
                       initialSpringVelocity: 0.5, options: [.curveEaseOut]) {
            stack.alpha = 1
            stack.transform = .identity
        }
    }

    // MARK: - Input handling

    private func handleInput() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return finishAfterMinimumDisplay()
        }
        let group = DispatchGroup()
        // Timestamp is captured here (extension may run without a foreground app).
        let now = Date()

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    group.enter()
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        if let data, let jpeg = Self.jpeg(from: data) {
                            SharedInbox.enqueue(kind: .image, imageData: jpeg, createdAt: now)
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                        if let url = value as? URL {
                            SharedInbox.enqueue(kind: .url, text: url.absoluteString, createdAt: now)
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, _ in
                        if let text = value as? String {
                            SharedInbox.enqueue(kind: .text, text: text, createdAt: now)
                        }
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.markPendingContext()
            self?.finishAfterMinimumDisplay()
        }
    }

    /// Re-encode to a bounded JPEG so shared images stay small for vision.
    private static func jpeg(from data: Data, maxDimension: CGFloat = 1600) -> Data? {
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.7)
    }

    /// Tells the app (via the shared App Group) that a fresh share is waiting,
    /// so it opens straight into the "instant context" screen on activation.
    private func markPendingContext() {
        let defaults = UserDefaults(suiteName: SharedInbox.appGroupID)
        defaults?.set(true, forKey: "pendingContext")
        defaults?.set(Date().timeIntervalSince1970, forKey: "pendingContextAt")
    }

    /// Waits out the minimum confirmation display time (so the checkmark
    /// doesn't flash by unreadably fast) before handing control back.
    private func finishAfterMinimumDisplay() {
        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = max(0, minimumDisplay - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        openHostApp()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// Jump straight into ARCA so the action sheet appears without a second
    /// tap. Extensions can't touch UIApplication.shared, so we walk the
    /// responder chain up to the hosting app and ask it to open our URL.
    private func openHostApp() {
        guard let url = URL(string: "arca://context") else { return }
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }
}
