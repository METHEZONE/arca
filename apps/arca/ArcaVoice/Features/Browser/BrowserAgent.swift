#if os(macOS)
import AppKit
import Foundation
import WebKit
import ArcaVoiceKit

/// ARCA's own browser agent. A WKWebView lives in an ARCA window; the model
/// sees screenshots of it and acts through Anthropic's computer-use tool,
/// which ARCA translates into DOM events on the page. Logins persist in the
/// web view's data store, so the user signs in once and ARCA works inside
/// that session from then on — no extension, no external CLI.
///
/// Every step is written to `steps` (with a thumbnail) so the window shows
/// what ARCA is doing; clicks on anything that looks like paying, sending,
/// deleting or publishing stop for the user's approval first.
@MainActor
@Observable
final class BrowserAgent {
    static let shared = BrowserAgent()

    /// Fixed viewport so model coordinates map 1:1 onto CSS pixels.
    static let viewport = CGSize(width: 1024, height: 768)
    static let model = "claude-opus-5"
    static let maxSteps = 40

    struct Step: Identifiable {
        enum Kind { case action, thought, result, error, approval, info }
        let id = UUID()
        let time = Date()
        var kind: Kind
        var label: String
        var detail: String = ""
        var thumbnail: NSImage?
    }

    /// Something the loop is waiting on the user for.
    struct Pending: Identifiable {
        enum Kind { case approval, userTurn }
        let id = UUID()
        let kind: Kind
        let text: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var steps: [Step] = []
    private(set) var isRunning = false
    private(set) var currentTask = ""
    private(set) var status = ""
    private(set) var lastResult = ""
    var pending: Pending?
    var currentURL = ""
    var pageTitle = ""

    let webView: WKWebView
    private let navigationDelegate = NavigationDelegate()
    private var runTask: Task<Void, Never>?

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(
            WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(origin: .zero, size: Self.viewport), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = navigationDelegate
        navigationDelegate.onChange = { [weak self] url, title in
            self?.currentURL = url
            self?.pageTitle = title
        }
        if webView.url == nil {
            webView.load(URLRequest(url: URL(string: "https://duckduckgo.com")!))
        }
    }

    // MARK: - Public

    var isAvailable: Bool { ArcaCloud.anthropicKey != nil }

    func load(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            if text.contains(".") && !text.contains(" ") { text = "https://" + text }
            else { text = "https://duckduckgo.com/?q=" + (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text) }
        }
        guard let url = URL(string: text) else { return }
        webView.load(URLRequest(url: url))
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if let pending { pending.continuation.resume(returning: false); self.pending = nil }
        isRunning = false
        status = L("중단했어요", "Stopped")
    }

    func resolvePending(_ answer: Bool) {
        guard let pending else { return }
        self.pending = nil
        pending.continuation.resume(returning: answer)
    }

    /// Runs a task and streams human-readable progress lines. The final line
    /// is the result the model reported (also kept in `lastResult`).
    func run(task: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            if isRunning {
                continuation.yield(L("이미 다른 브라우저 작업 중이에요", "A browser task is already running"))
                continuation.finish()
                return
            }
            BrowserAgentWindow.present()
            steps.removeAll()
            currentTask = task
            isRunning = true
            lastResult = ""
            status = L("시작하는 중…", "Starting…")
            runTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.loop(task: task) { line in continuation.yield(line) }
                    self.lastResult = result
                    self.status = L("완료", "Done")
                    continuation.yield(result)
                } catch is CancellationError {
                    self.lastResult = L("사용자가 중단했어요", "Stopped by the user")
                    continuation.yield(self.lastResult)
                } catch {
                    self.lastResult = L("브라우저 작업 실패: ", "Browser task failed: ") + error.localizedDescription
                    self.status = L("실패", "Failed")
                    self.append(.error, self.lastResult)
                    continuation.yield(self.lastResult)
                }
                self.isRunning = false
                self.runTask = nil
                continuation.finish()
            }
        }
    }

    // MARK: - Agent loop

    private func loop(task: String, emit: @escaping (String) -> Void) async throws -> String {
        var messages: [[String: Any]] = []
        let opener = try await screenshotBlock()
        messages.append(["role": "user", "content": [
            ["type": "text", "text": "Task: \(task)\n\nThe current page is shown below. Begin."],
            opener,
        ]])
        append(.info, L("작업 시작", "Task started"), detail: task, thumbnail: lastThumbnail)

        for round in 1...Self.maxSteps {
            try Task.checkCancellation()
            status = L("생각하는 중… (\(round))", "Thinking… (\(round))")
            let response = try await callClaude(messages: messages)
            let content = response["content"] as? [[String: Any]] ?? []
            let stopReason = response["stop_reason"] as? String ?? ""
            messages.append(["role": "assistant", "content": content])

            for block in content where block["type"] as? String == "text" {
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    append(.thought, String(text.prefix(300)))
                    emit(String(text.prefix(300)))
                }
            }

            let toolUses = content.filter { $0["type"] as? String == "tool_use" }
            if stopReason != "tool_use" || toolUses.isEmpty {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                return text.isEmpty ? L("끝났어요.", "Finished.") : text
            }

            var results: [[String: Any]] = []
            for use in toolUses {
                try Task.checkCancellation()
                let id = use["id"] as? String ?? UUID().uuidString
                let name = use["name"] as? String ?? ""
                let input = use["input"] as? [String: Any] ?? [:]
                switch name {
                case "computer":
                    let (text, screenshot) = await perform(input: input)
                    emit(text)
                    var parts: [[String: Any]] = [["type": "text", "text": text]]
                    if let screenshot { parts.append(screenshot) }
                    results.append(["type": "tool_result", "tool_use_id": id, "content": parts])
                case "navigate":
                    let url = input["url"] as? String ?? ""
                    load(url)
                    await settle(after: 1.2)
                    let text = L("이동: ", "Went to ") + url
                    append(.action, text, thumbnail: nil)
                    emit(text)
                    var parts: [[String: Any]] = [["type": "text", "text": "Navigated to \(url). Now at \(currentURL)"]]
                    if let shot = try? await screenshotBlock() { parts.append(shot) }
                    results.append(["type": "tool_result", "tool_use_id": id, "content": parts])
                case "read_page":
                    let max = input["max_chars"] as? Int ?? 12_000
                    let text = (try? await js("__arca.text(\(max))")) as? String ?? ""
                    append(.action, L("페이지 읽기", "Reading the page"), detail: String(text.prefix(120)))
                    emit(L("페이지 읽기", "Reading the page"))
                    results.append(["type": "tool_result", "tool_use_id": id, "content": text.isEmpty ? "(empty page)" : text])
                case "select_option":
                    let coord = input["coordinate"] as? [Any] ?? []
                    let x = (coord.first as? NSNumber)?.intValue ?? 0, y = (coord.dropFirst().first as? NSNumber)?.intValue ?? 0
                    let label = input["option"] as? String ?? ""
                    let text = (try? await js("__arca.selectOption(\(x),\(y),\(Self.jsString(label)))")) as? String ?? "failed"
                    append(.action, L("옵션 선택: ", "Select option: ") + label, detail: text)
                    var parts: [[String: Any]] = [["type": "text", "text": text]]
                    if let shot = try? await screenshotBlock() { parts.append(shot) }
                    results.append(["type": "tool_result", "tool_use_id": id, "content": parts])
                case "ask_user":
                    let question = input["question"] as? String ?? ""
                    append(.approval, L("사용자에게 질문", "Asking the user"), detail: question)
                    emit(L("사용자 확인 대기: ", "Waiting for the user: ") + question)
                    status = L("당신의 차례예요", "Your turn")
                    let ok = await waitForUser(kind: .userTurn, text: question)
                    var parts: [[String: Any]] = [["type": "text", "text": ok ? "The user says they are done / to continue. Take a fresh look at the page." : "The user cancelled. Wrap up with done(success=false)."]]
                    if let shot = try? await screenshotBlock() { parts.append(shot) }
                    results.append(["type": "tool_result", "tool_use_id": id, "content": parts])
                case "done":
                    let summary = input["summary"] as? String ?? ""
                    let success = input["success"] as? Bool ?? true
                    append(success ? .result : .error, success ? L("완료", "Done") : L("완료하지 못했어요", "Could not finish"), detail: summary, thumbnail: lastThumbnail)
                    return summary.isEmpty ? L("끝났어요.", "Finished.") : summary
                default:
                    results.append(["type": "tool_result", "tool_use_id": id, "content": "Unknown tool \(name)", "is_error": true])
                }
            }
            messages.append(["role": "user", "content": results])
            Self.pruneImages(in: &messages, keepLast: 3)
        }
        return L("단계 한도(\(Self.maxSteps))에 도달했어요. 지금까지 한 일은 브라우저 창에 있어요.",
                 "Reached the step limit (\(Self.maxSteps)). What was done so far is in the browser window.")
    }

    // MARK: - Computer tool actions

    private func perform(input: [String: Any]) async -> (String, [String: Any]?) {
        let action = input["action"] as? String ?? ""
        func coord(_ key: String) -> (Int, Int)? {
            guard let c = input[key] as? [Any], c.count >= 2,
                  let x = (c[0] as? NSNumber)?.intValue, let y = (c[1] as? NSNumber)?.intValue else { return nil }
            return (max(0, min(Int(Self.viewport.width) - 1, x)), max(0, min(Int(Self.viewport.height) - 1, y)))
        }
        var text = ""
        var wantsScreenshot = true
        do {
            switch action {
            case "screenshot":
                text = "screenshot"
                wantsScreenshot = true
            case "left_click", "right_click", "middle_click", "double_click", "triple_click":
                guard let (x, y) = coord("coordinate") else { text = "coordinate required"; break }
                let button = action == "right_click" ? "right" : (action == "middle_click" ? "middle" : "left")
                let count = action == "double_click" ? 2 : (action == "triple_click" ? 3 : 1)
                let target = (try? await js("__arca.describe(\(x),\(y))")) as? String ?? ""
                if Self.looksRisky(target) {
                    let question = L("「\(target)」를 클릭하려고 해요. 진행할까요?", "About to click “\(target)”. Go ahead?")
                    append(.approval, L("승인 필요", "Approval needed"), detail: question, thumbnail: lastThumbnail)
                    status = L("승인 대기", "Waiting for approval")
                    let ok = await waitForUser(kind: .approval, text: question)
                    if !ok {
                        text = "The user declined this click on \(target). Do not retry it; ask or finish."
                        wantsScreenshot = false
                        break
                    }
                }
                let result = (try await js("__arca.click(\(x),\(y),'\(button)',\(count))")) as? String ?? ""
                text = "\(action) at (\(x),\(y)) on \(result)"
                append(.action, L("클릭", "Click") + " \(target.isEmpty ? "(\(x),\(y))" : target)")
                await settle(after: 0.6)
            case "type":
                let value = input["text"] as? String ?? ""
                let result = (try await js("__arca.type(\(Self.jsString(value)))")) as? String ?? ""
                text = "typed \(value.count) chars: \(result)"
                append(.action, L("입력: ", "Type: ") + String(value.prefix(60)))
                await settle(after: 0.3)
            case "key":
                let combo = input["text"] as? String ?? ""
                let result = (try await js("__arca.key(\(Self.jsString(combo)))")) as? String ?? ""
                text = result
                append(.action, L("키: ", "Key: ") + combo)
                await settle(after: 0.6)
            case "scroll":
                let (x, y) = coord("coordinate") ?? (Int(Self.viewport.width / 2), Int(Self.viewport.height / 2))
                let direction = input["scroll_direction"] as? String ?? "down"
                let amount = (input["scroll_amount"] as? NSNumber)?.intValue ?? 3
                text = (try await js("__arca.scroll(\(x),\(y),'\(direction)',\(amount))")) as? String ?? ""
                append(.action, L("스크롤 ", "Scroll ") + direction)
                await settle(after: 0.4)
            case "mouse_move":
                guard let (x, y) = coord("coordinate") else { text = "coordinate required"; break }
                text = "moved to (\(x),\(y)): " + ((try await js("__arca.move(\(x),\(y))")) as? String ?? "")
                wantsScreenshot = false
            case "left_click_drag":
                guard let (x0, y0) = coord("start_coordinate"), let (x1, y1) = coord("coordinate") else { text = "start_coordinate and coordinate required"; break }
                text = (try await js("__arca.drag(\(x0),\(y0),\(x1),\(y1))")) as? String ?? ""
                append(.action, L("드래그", "Drag"))
                await settle(after: 0.4)
            case "left_mouse_down":
                guard let (x, y) = coord("coordinate") else { text = "coordinate required"; break }
                text = (try await js("__arca.down(\(x),\(y))")) as? String ?? ""
                wantsScreenshot = false
            case "left_mouse_up":
                guard let (x, y) = coord("coordinate") else { text = "coordinate required"; break }
                text = (try await js("__arca.up(\(x),\(y))")) as? String ?? ""
                await settle(after: 0.4)
            case "hold_key":
                let combo = input["text"] as? String ?? ""
                text = (try await js("__arca.key(\(Self.jsString(combo)))")) as? String ?? ""
                await settle(after: 0.3)
            case "wait":
                let seconds = min(5.0, (input["duration"] as? NSNumber)?.doubleValue ?? 1.0)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                text = "waited \(seconds)s"
            case "cursor_position":
                text = (try await js("__arca.cursor()")) as? String ?? "{}"
                wantsScreenshot = false
            case "zoom":
                guard let region = input["region"] as? [Any], region.count == 4 else { text = "region required"; break }
                let values = region.compactMap { ($0 as? NSNumber)?.doubleValue }
                guard values.count == 4 else { text = "region must be 4 numbers"; break }
                let rect = CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
                if let image = try? await snapshot(), let png = Self.png(image, cropping: rect) {
                    append(.action, L("확대해서 보기", "Zooming in"))
                    return ("zoomed into \(Int(rect.minX)),\(Int(rect.minY))–\(Int(rect.maxX)),\(Int(rect.maxY))", Self.imageBlock(png))
                }
                text = "zoom failed"
            default:
                text = "Unsupported action \(action)"
                wantsScreenshot = false
            }
        } catch {
            text = "\(action) failed: \(error.localizedDescription)"
            append(.error, text)
        }
        if wantsScreenshot, let block = try? await screenshotBlock() {
            if let last = steps.indices.last, steps[last].thumbnail == nil, steps[last].kind == .action {
                steps[last].thumbnail = lastThumbnail
            }
            return (text, block)
        }
        return (text, nil)
    }

    private static let riskyPattern = try! NSRegularExpression(
        pattern: #"결제|구매|주문|pay\b|buy\b|checkout|purchase|place order|삭제|delete|remove|보내기|전송|\bsend\b|게시|publish|\bpost\b|tweet|송금|transfer"#,
        options: [.caseInsensitive])

    static func looksRisky(_ description: String) -> Bool {
        let range = NSRange(description.startIndex..., in: description)
        return riskyPattern.firstMatch(in: description, range: range) != nil
    }

    private func waitForUser(kind: Pending.Kind, text: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            pending = Pending(kind: kind, text: text, continuation: continuation)
        }
    }

    /// Lets navigations kicked off by an action land before the next screenshot.
    private func settle(after seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        var waited = 0.0
        while webView.isLoading && waited < 6 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
        }
    }

    // MARK: - JS bridge

    @discardableResult
    private func js(_ script: String) async throws -> Any? {
        let present = try await webView.evaluateJavaScript("typeof window.__arca") as? String
        if present != "object" {
            _ = try await webView.evaluateJavaScript(Self.bridgeScript)
        }
        return try await webView.evaluateJavaScript(script)
    }

    static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Screenshots

    private(set) var lastThumbnail: NSImage?

    private func snapshot() async throws -> NSImage {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? AgentError.snapshot) }
            }
        }
    }

    private func screenshotBlock() async throws -> [String: Any] {
        let image = try await snapshot()
        guard let png = Self.png(image, cropping: nil) else { throw AgentError.snapshot }
        lastThumbnail = Self.thumbnail(image)
        return Self.imageBlock(png)
    }

    static func imageBlock(_ png: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
    }

    /// Renders the snapshot at exactly the viewport's pixel size (the snapshot
    /// itself is Retina) so model coordinates are CSS pixels. A crop rect (in
    /// viewport coordinates) is scaled up to fill the viewport width.
    static func png(_ image: NSImage, cropping: CGRect?) -> Data? {
        let source = cropping ?? CGRect(origin: .zero, size: viewport)
        guard source.width > 4, source.height > 4 else { return nil }
        let scale = min(viewport.width / source.width, viewport.height / source.height)
        let target = CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: target).fill()
        // NSImage coordinates are flipped relative to CSS: y grows upward.
        let fromRect = CGRect(x: source.minX, y: image.size.height - source.maxY, width: source.width, height: source.height)
        image.draw(in: CGRect(origin: .zero, size: target), from: fromRect, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func thumbnail(_ image: NSImage) -> NSImage {
        let size = CGSize(width: 240, height: 180)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    /// Older screenshots are dropped from the transcript: the page has moved
    /// on, and each one is ~1k tokens.
    static func pruneImages(in messages: inout [[String: Any]], keepLast: Int) {
        var imageSlots: [(Int, Int, Int?)] = [] // message, content index, tool_result content index
        for (m, message) in messages.enumerated() where message["role"] as? String == "user" {
            guard let content = message["content"] as? [[String: Any]] else { continue }
            for (c, block) in content.enumerated() {
                if block["type"] as? String == "image" { imageSlots.append((m, c, nil)) }
                if block["type"] as? String == "tool_result", let inner = block["content"] as? [[String: Any]] {
                    for (i, part) in inner.enumerated() where part["type"] as? String == "image" { imageSlots.append((m, c, i)) }
                }
            }
        }
        guard imageSlots.count > keepLast else { return }
        let placeholder: [String: Any] = ["type": "text", "text": "(earlier screenshot omitted)"]
        for (m, c, i) in imageSlots.dropLast(keepLast) {
            var message = messages[m]
            var content = message["content"] as? [[String: Any]] ?? []
            if let i {
                var block = content[c]
                var inner = block["content"] as? [[String: Any]] ?? []
                inner[i] = placeholder
                block["content"] = inner
                content[c] = block
            } else {
                content[c] = placeholder
            }
            message["content"] = content
            messages[m] = message
        }
    }

    // MARK: - Model call

    private func callClaude(messages: [[String: Any]]) async throws -> [String: Any] {
        guard let key = ArcaCloud.anthropicKey else { throw AgentError.noKey }
        var request = URLRequest(url: ArcaCloud.anthropicMessagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4096,
            "output_config": ["effort": "medium"],
            "system": Self.systemPrompt,
            "tools": Self.tools,
            "messages": messages,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                AIUsageLog.recordResponse(provider: "anthropic", model: Self.model, source: "browser", data: data)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentError.badResponse }
                return json
            }
            if (status == 429 || status >= 500) && attempt < 4 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                continue
            }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AgentError.api(status, message)
        }
    }

    static var tools: [[String: Any]] {
        [
            ["type": "computer_20251124", "name": "computer",
             "display_width_px": Int(viewport.width), "display_height_px": Int(viewport.height)],
            ["name": "navigate", "description": "Load a URL in the browser. Prefer this over typing into the address bar.",
             "input_schema": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]],
            ["name": "read_page", "description": "Return the visible text of the current page (title, URL, body text). Much cheaper than scrolling through screenshots when you need to read content.",
             "input_schema": ["type": "object", "properties": ["max_chars": ["type": "integer", "description": "Default 12000."]]]],
            ["name": "select_option", "description": "Choose an option in a native <select> dropdown at the given coordinate by its visible label. Native dropdowns cannot be opened by clicking here.",
             "input_schema": ["type": "object", "properties": ["coordinate": ["type": "array", "items": ["type": "integer"]], "option": ["type": "string"]], "required": ["coordinate", "option"]]],
            ["name": "ask_user", "description": "Pause and hand control to the user — e.g. a login page, a CAPTCHA, a 2FA code, or a choice only they can make. They act in the same browser window and press Continue. Then look at the page again.",
             "input_schema": ["type": "object", "properties": ["question": ["type": "string"]], "required": ["question"]]],
            ["name": "done", "description": "Finish the task. Summarize what was accomplished and anything found, in the user's language.",
             "input_schema": ["type": "object", "properties": ["summary": ["type": "string"], "success": ["type": "boolean"]], "required": ["summary", "success"]]],
        ]
    }

    static let systemPrompt = """
    You are ARCA operating a real browser window on the user's Mac for them. You see the page as \(Int(viewport.width))×\(Int(viewport.height)) screenshots and act with the computer tool; coordinates are pixels in that image.

    How to work:
    - Use `navigate` for URLs and `read_page` to read content; take a screenshot only when you need to see layout or find where to click.
    - For web search use https://duckduckgo.com/?q=… (or naver.com for Korean topics). Google usually shows a CAPTCHA in this browser; avoid it unless the task names Google.
    - Click precisely on the visible control. After typing into a search box, press Return. Use `select_option` for native dropdowns.
    - If the page needs a login, CAPTCHA, or a decision only the user can make, call `ask_user` — the user acts in this same window and their session stays for next time.
    - Never buy, pay, send, post, or delete without it being clearly part of the task; ARCA will ask the user before such clicks anyway.
    - Be economical: don't scroll through pages you can read with `read_page`; don't re-screenshot the same unchanged view.
    - Finish with `done` and a concise summary in the user's language (Korean if the task is in Korean), including concrete results (names, numbers, links).
    """

    // MARK: - Types

    enum AgentError: LocalizedError {
        case noKey, snapshot, badResponse, api(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return L("모델 키가 없어요. 설정에서 Anthropic 키나 초대 코드를 넣어주세요.", "No model key. Add an Anthropic key or an invite code in Settings.")
            case .snapshot: return L("화면을 캡처하지 못했어요", "Could not capture the page")
            case .badResponse: return L("모델 응답을 읽지 못했어요", "Unreadable model response")
            case .api(let status, let message): return "HTTP \(status): \(message)"
            }
        }
    }

    private func append(_ kind: Step.Kind, _ label: String, detail: String = "", thumbnail: NSImage? = nil) {
        steps.append(Step(kind: kind, label: label, detail: detail, thumbnail: thumbnail))
        DebugTrace.log("browser: [\(kind)] \(label)\(detail.isEmpty ? "" : " — " + String(detail.prefix(240)))")
        if steps.count > 200 { steps.removeFirst(steps.count - 200) }
    }

    // MARK: - Page bridge

    /// Injected into every page: turns model actions into DOM events.
    static let bridgeScript = #"""
    (function () {
      if (window.__arca) return;
      const A = {};
      let cursor = { x: 0, y: 0 };
      const el = (x, y) => document.elementFromPoint(x, y);
      function mouse(type, target, x, y, button, detail) {
        const ev = new MouseEvent(type, { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y,
          screenX: x, screenY: y, button: button, buttons: type === 'mousedown' ? (button === 2 ? 2 : 1) : 0, detail: detail || 1 });
        target.dispatchEvent(ev);
        return ev;
      }
      function pointer(type, target, x, y, button) {
        try { target.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y,
          button: button, pointerId: 1, pointerType: 'mouse', isPrimary: true })); } catch (e) {}
      }
      A.describe = function (x, y) {
        const t = el(x, y); if (!t) return '';
        const tag = t.tagName.toLowerCase();
        const text = (t.innerText || t.value || t.getAttribute('aria-label') || t.getAttribute('placeholder') || t.getAttribute('title') || '').trim().replace(/\s+/g, ' ').slice(0, 80);
        return tag + (t.id ? '#' + t.id : '') + (text ? ' "' + text + '"' : '');
      };
      A.move = function (x, y) {
        cursor = { x, y }; const t = el(x, y);
        if (t) { pointer('pointermove', t, x, y, 0); mouse('mousemove', t, x, y, 0); }
        return A.describe(x, y);
      };
      A.click = function (x, y, button, count) {
        cursor = { x, y }; const t = el(x, y); if (!t) return 'nothing at ' + x + ',' + y;
        const b = button === 'right' ? 2 : (button === 'middle' ? 1 : 0);
        pointer('pointermove', t, x, y, 0); mouse('mousemove', t, x, y, 0);
        for (let i = 1; i <= count; i++) {
          pointer('pointerdown', t, x, y, b); mouse('mousedown', t, x, y, b, i);
          if (typeof t.focus === 'function') t.focus();
          pointer('pointerup', t, x, y, b); mouse('mouseup', t, x, y, b, i);
          if (b === 0) mouse('click', t, x, y, 0, i);
          if (b === 2) mouse('contextmenu', t, x, y, 2, i);
        }
        if (b === 0 && count === 2) mouse('dblclick', t, x, y, 0, 2);
        if (b === 0 && count === 3) {
          try { const r = document.createRange(); r.selectNodeContents(t); const s = getSelection(); s.removeAllRanges(); s.addRange(r); } catch (e) {}
        }
        const editable = t.closest && t.closest('input,textarea,[contenteditable="true"],[contenteditable=""],[contenteditable="plaintext-only"]');
        if (editable && document.activeElement !== editable) editable.focus();
        return A.describe(x, y);
      };
      A.type = function (text) {
        let t = document.activeElement;
        if (!t || t === document.body) return 'no focused element — click an input first';
        const isInput = t.tagName === 'INPUT' || t.tagName === 'TEXTAREA';
        if (isInput || t.isContentEditable) {
          let ok = false;
          try { ok = document.execCommand('insertText', false, text); } catch (e) {}
          if (!ok && isInput) {
            const start = t.selectionStart ?? t.value.length, end = t.selectionEnd ?? t.value.length;
            t.value = t.value.slice(0, start) + text + t.value.slice(end);
            const p = start + text.length; try { t.setSelectionRange(p, p); } catch (e) {}
            t.dispatchEvent(new Event('input', { bubbles: true }));
          } else if (!ok) {
            t.textContent += text;
            t.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
          }
          return 'typed into ' + A.describe(cursor.x, cursor.y);
        }
        for (const ch of text) A.key(ch);
        return 'sent as key presses (no text field focused)';
      };
      const KEYMAP = { Return: 'Enter', enter: 'Enter', KP_Enter: 'Enter', Tab: 'Tab', tab: 'Tab', Escape: 'Escape', esc: 'Escape',
        BackSpace: 'Backspace', backspace: 'Backspace', Delete: 'Delete', space: ' ', Up: 'ArrowUp', Down: 'ArrowDown',
        Left: 'ArrowLeft', Right: 'ArrowRight', Page_Down: 'PageDown', Page_Up: 'PageUp', Home: 'Home', End: 'End' };
      A.key = function (combo) {
        const parts = combo.split('+'); const raw = parts.pop();
        const key = KEYMAP[raw] || KEYMAP[raw.toLowerCase()] || raw;
        const mods = parts.map(p => p.toLowerCase());
        const opts = { key: key, code: key, bubbles: true, cancelable: true,
          ctrlKey: mods.includes('ctrl') || mods.includes('control'),
          metaKey: mods.includes('cmd') || mods.includes('meta') || mods.includes('super') || mods.includes('command'),
          altKey: mods.includes('alt') || mods.includes('option'), shiftKey: mods.includes('shift') };
        const t = document.activeElement || document.body;
        const prevented = !t.dispatchEvent(new KeyboardEvent('keydown', opts));
        const isInput = t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable;
        if (!prevented) {
          if ((opts.metaKey || opts.ctrlKey) && key.toLowerCase() === 'a') { if (isInput && t.select) t.select(); else document.execCommand('selectAll'); }
          else if (key === 'Backspace' && isInput) document.execCommand('delete');
          else if (key === 'Delete' && isInput) document.execCommand('forwardDelete');
          else if (key === 'Enter') {
            if (t.tagName === 'TEXTAREA' || (t.isContentEditable && !opts.metaKey && !opts.ctrlKey)) document.execCommand('insertParagraph');
            else if (t.form) { if (t.form.requestSubmit) t.form.requestSubmit(); else t.form.submit(); }
            else if (t.tagName === 'A' || t.tagName === 'BUTTON' || t.getAttribute('role') === 'button') t.click();
          }
          else if (key === 'Tab') {
            const f = [...document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])')].filter(e => !e.disabled && e.offsetParent !== null);
            const i = f.indexOf(t); const n = f[(i + (opts.shiftKey ? -1 : 1) + f.length) % f.length]; if (n) n.focus();
          }
          else if (key === 'Escape') { if (t.blur) t.blur(); }
          else if (key === 'PageDown') window.scrollBy(0, innerHeight * 0.9);
          else if (key === 'PageUp') window.scrollBy(0, -innerHeight * 0.9);
          else if (key === 'Home' && !isInput) window.scrollTo(0, 0);
          else if (key === 'End' && !isInput) window.scrollTo(0, document.body.scrollHeight);
          else if (key === ' ' && isInput) document.execCommand('insertText', false, ' ');
          else if (key.length === 1 && isInput && !opts.metaKey && !opts.ctrlKey) document.execCommand('insertText', false, key);
        }
        t.dispatchEvent(new KeyboardEvent('keypress', opts));
        t.dispatchEvent(new KeyboardEvent('keyup', opts));
        return 'key ' + combo + (prevented ? ' (handled by page)' : '');
      };
      A.scroll = function (x, y, dir, amount) {
        const px = amount * 100; let dx = 0, dy = 0;
        if (dir === 'down') dy = px; if (dir === 'up') dy = -px; if (dir === 'right') dx = px; if (dir === 'left') dx = -px;
        let t = el(x, y), s = null;
        while (t && t !== document.body && t !== document.documentElement) {
          const cs = getComputedStyle(t);
          if (((cs.overflowY === 'auto' || cs.overflowY === 'scroll') && t.scrollHeight > t.clientHeight && dy) ||
              ((cs.overflowX === 'auto' || cs.overflowX === 'scroll') && t.scrollWidth > t.clientWidth && dx)) { s = t; break; }
          t = t.parentElement;
        }
        if (s) s.scrollBy(dx, dy); else window.scrollBy(dx, dy);
        return 'scrolled ' + dir + ' ' + amount;
      };
      A.text = function (max) {
        const body = (document.body && document.body.innerText) || '';
        return (document.title || '') + '\n' + location.href + '\n\n' + body.slice(0, max);
      };
      A.drag = function (x0, y0, x1, y1) {
        const s = el(x0, y0); if (!s) return 'nothing at start';
        pointer('pointerdown', s, x0, y0, 0); mouse('mousedown', s, x0, y0, 0);
        for (let i = 1; i <= 8; i++) {
          const x = x0 + (x1 - x0) * i / 8, y = y0 + (y1 - y0) * i / 8; const t = el(x, y) || s;
          pointer('pointermove', t, x, y, 0); mouse('mousemove', t, x, y, 0);
        }
        const e = el(x1, y1) || s; pointer('pointerup', e, x1, y1, 0); mouse('mouseup', e, x1, y1, 0);
        cursor = { x: x1, y: y1 }; return 'dragged to ' + x1 + ',' + y1;
      };
      A.down = function (x, y) { cursor = { x, y }; const t = el(x, y); if (t) { pointer('pointerdown', t, x, y, 0); mouse('mousedown', t, x, y, 0); } return 'mouse down'; };
      A.up = function (x, y) { const t = el(x, y); if (t) { pointer('pointerup', t, x, y, 0); mouse('mouseup', t, x, y, 0); mouse('click', t, x, y, 0); } return 'mouse up'; };
      A.cursor = function () { return JSON.stringify(cursor); };
      A.selectOption = function (x, y, label) {
        const t = el(x, y); const sel = t && (t.tagName === 'SELECT' ? t : t.closest('select'));
        if (!sel) return 'no <select> at that point';
        const opts = [...sel.options]; const want = label.trim().toLowerCase();
        const o = opts.find(o => o.text.trim().toLowerCase() === want) || opts.find(o => o.text.toLowerCase().includes(want) || o.value.toLowerCase() === want);
        if (!o) return 'no option matching "' + label + '"; options: ' + opts.map(o => o.text.trim()).slice(0, 40).join(' | ');
        sel.value = o.value;
        sel.dispatchEvent(new Event('input', { bubbles: true })); sel.dispatchEvent(new Event('change', { bubbles: true }));
        return 'selected ' + o.text.trim();
      };
      window.__arca = A;
    })();
    """#
}

/// Reports URL/title changes and keeps popups in the same view.
final class NavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onChange: ((String, String) -> Void)?

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { report(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { report(webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(webView) }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    private func report(_ webView: WKWebView) {
        let url = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        Task { @MainActor in self.onChange?(url, title) }
    }
}
#endif
