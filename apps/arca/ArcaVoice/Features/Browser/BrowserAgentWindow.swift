#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import ArcaVoiceKit

/// The browser ARCA drives: address bar, the page itself (fixed 1024×768 so
/// the model's coordinates are exact), a task field, and a running log of
/// each step with thumbnails. Approvals and "your turn" prompts appear above
/// the log with 네/아니요 buttons.
@MainActor
enum BrowserAgentWindow {
    private static var window: NSWindow?

    static func present() {
        if window == nil {
            let hosting = NSHostingController(rootView: BrowserAgentView())
            let w = NSWindow(contentViewController: hosting)
            w.title = L("ARCA 브라우저", "ARCA Browser")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: BrowserAgent.viewport.width + 340, height: BrowserAgent.viewport.height + 96))
            w.minSize = NSSize(width: BrowserAgent.viewport.width + 340, height: BrowserAgent.viewport.height + 96)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in window = nil }
            }
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct BrowserAgentView: View {
    @State private var agent = BrowserAgent.shared
    @State private var addressText = ""
    @State private var taskText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            HStack(spacing: 0) {
                WebViewContainer(webView: agent.webView)
                    .frame(width: BrowserAgent.viewport.width, height: BrowserAgent.viewport.height)
                    .clipped()
                Divider()
                sidePanel
            }
        }
        .frame(minWidth: BrowserAgent.viewport.width + 340, minHeight: BrowserAgent.viewport.height + 96)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: agent.currentURL, initial: true) { _, url in
            if !addressFocused { addressText = url }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { agent.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!agent.webView.canGoBack)
            Button { agent.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!agent.webView.canGoForward)
            Button { agent.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
            TextField(L("주소 또는 검색어", "Address or search"), text: $addressText)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit { agent.load(addressText); addressFocused = false }
            if agent.isRunning {
                ProgressView().controlSize(.small)
                Text(agent.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(L("중단", "Stop")) { agent.cancel() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.top, 34).padding(.bottom, 8)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ArcaFace(mood: agent.isRunning ? .thinking : .idle, size: 26, halo: false)
                    .frame(width: 30, height: 30)
                Text(L("ARCA에게 시킬 일", "What should ARCA do here?"))
                    .font(.system(.headline, design: .rounded, weight: .bold))
            }
            TextField(L("예: 쿠팡에서 A4 복사용지 최저가 찾아줘", "e.g. find the cheapest A4 paper on Amazon"),
                      text: $taskText, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(startTask)
                .disabled(agent.isRunning)
            HStack {
                Spacer()
                Button(action: startTask) {
                    Label(L("실행", "Run"), systemImage: "play.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(agent.isRunning || taskText.trimmingCharacters(in: .whitespaces).isEmpty || !agent.isAvailable)
            }
            if !agent.isAvailable {
                Text(L("모델 키나 초대 코드가 없어서 자동 작업은 꺼져 있어요. 브라우저로는 그냥 쓸 수 있어요.",
                       "No model key or invite code, so automatic tasks are off. You can still browse."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let pending = agent.pending {
                pendingCard(pending)
            }

            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if agent.steps.isEmpty {
                            Text(L("작업을 시작하면 ARCA가 하는 일이 여기 한 단계씩 보여요. 로그인이 필요한 사이트는 여기서 먼저 한 번 로그인해두면 계속 유지돼요.",
                                   "Each step ARCA takes shows up here. Sign in to sites you need once in this window; the session sticks."))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(agent.steps) { step in
                            stepRow(step).id(step.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: agent.steps.count) { _, _ in
                    if let last = agent.steps.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if !agent.lastResult.isEmpty && !agent.isRunning {
                Divider()
                Text(agent.lastResult)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
        }
        .padding(14)
        .frame(width: 339)
    }

    private func pendingCard(_ pending: BrowserAgent.Pending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(pending.kind == .approval ? L("승인이 필요해요", "Approval needed") : L("당신의 차례예요", "Your turn"),
                  systemImage: pending.kind == .approval ? "hand.raised.fill" : "person.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(pending.kind == .approval ? .orange : .blue)
            Text(pending.text).font(.callout)
            HStack {
                Button(pending.kind == .approval ? L("네, 진행", "Yes, go ahead") : L("했어요, 계속", "Done, continue")) {
                    agent.resolvePending(true)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Button(pending.kind == .approval ? L("아니요", "No") : L("취소", "Cancel")) {
                    agent.resolvePending(false)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(pending.kind == .approval ? 0.12 : 0.0)))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(pending.kind == .userTurn ? 0.10 : 0.0)))
    }

    private func stepRow(_ step: BrowserAgent.Step) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: step.kind))
                .font(.caption)
                .foregroundStyle(color(for: step.kind))
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.label).font(.callout.weight(step.kind == .result ? .semibold : .regular))
                if !step.detail.isEmpty {
                    Text(step.detail).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                }
                if let thumb = step.thumbnail {
                    Image(nsImage: thumb)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
                }
            }
        }
    }

    private func icon(for kind: BrowserAgent.Step.Kind) -> String {
        switch kind {
        case .action: return "cursorarrow.click"
        case .thought: return "bubble.left"
        case .result: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .approval: return "hand.raised.fill"
        case .info: return "flag.fill"
        }
    }

    private func color(for kind: BrowserAgent.Step.Kind) -> Color {
        switch kind {
        case .action: return .blue
        case .thought: return .secondary
        case .result: return .green
        case .error: return .red
        case .approval: return .orange
        case .info: return .purple
        }
    }

    private func startTask() {
        let task = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !agent.isRunning else { return }
        taskText = ""
        Task { for await _ in agent.run(task: task) {} }
    }
}

/// Hosts the agent's single WKWebView instance.
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
