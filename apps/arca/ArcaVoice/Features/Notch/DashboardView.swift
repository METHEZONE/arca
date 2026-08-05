#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The hover dashboard that drops out of the notch: our chat history on the
/// left (with a way to keep talking), your live to-do tracker on the right
/// (quick-add + ARCA's "Toss" for anything it can run itself), and Record /
/// ZONE / app shortcuts up top. The main window stays the library; this is
/// the ambient, always-one-hover-away surface.
struct DashboardView: View {
    let agent: NotchAgent
    @State private var zone = AppServices.shared.zone
    @State private var relay = RelaySync.shared
    @State private var vitals = VitalsEngine.shared
    @State private var usageSnapshot = AIUsageSnapshot.loading

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 0) {
                ChatLogColumn(agent: agent)
                    .frame(maxWidth: .infinity)
                Divider().overlay(.white.opacity(0.08))
                TodoColumn()
                    .frame(width: 340)
            }
            .frame(maxHeight: .infinity)
            Divider().overlay(.white.opacity(0.08))
            HStack(alignment: .top, spacing: 12) {
                AIUsageMeter(snapshot: usageSnapshot)
                Spacer()
                syncHealth
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .task {
            usageSnapshot = await AIUsageSnapshot.load()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            miniEyes
            Text("ARCA")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
            Spacer()
            focusPill
            recordButton
            ZoneToggle(zone: zone)
            Button {
                agent.openApp()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.arcaPress)
            .help(L("ARCA 앱 열기", "Open the ARCA app"))
        }
        .padding(.vertical, 10)
    }

    private var recordButton: some View {
        Button {
            AppServices.shared.startRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text(L("녹음", "Record"))
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(ArcaTheme.recording.opacity(0.9), in: Capsule())
        }
        .buttonStyle(.arcaPress)
        .help(L("녹음 시작 — 실시간 기록, 화자 분리",
                "Start recording — live transcript, speakers separated"))
    }

    private var miniEyes: some View {
        ArcaFace(mood: .idle, size: 22, halo: false)
            .frame(width: 24, height: 24)
    }

    /// The body read, one glance from the notch. The number the Mac shows was
    /// measured on the iPhone and arrived through the relay — macOS has no
    /// HealthKit of its own, so an empty ring here means the phone hasn't synced
    /// yet, not that the user is at zero.
    private var focusPill: some View {
        HStack(spacing: 5) {
            FocusRing(score: vitals.ringScore, isLive: vitals.ringIsLive,
                      lineWidth: 3, trackOpacity: 0.16)
                .frame(width: 16, height: 16)
            Text(vitals.ringScore.map(String.init) ?? "—")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(vitals.ringScore == nil ? .white.opacity(0.45) : .white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.white.opacity(0.10), in: Capsule())
        .help(vitalsTooltip)
    }

    private var vitalsTooltip: String {
        guard vitals.ringScore != nil else {
            return L("아직 측정된 컨디션이 없어요 — 아이폰 ARCA에서 건강 권한을 허용하면 여기에 들어옵니다.",
                     "No reading yet — allow Health access in ARCA on your iPhone and it shows up here.")
        }
        var line = vitals.ringLabel
        if let next = vitals.nextFocusWindow() {
            line += L(" · 다음 골든타임 \(next.label)", " · Next focus window \(next.label)")
        }
        return line
    }

    /// iPhone↔Mac relay health — a broken token or dead network used to fail
    /// in total silence while the devices quietly drifted apart.
    @ViewBuilder private var syncHealth: some View {
        if let error = relay.lastError {
            Label {
                Text(L("동기화 실패 — \(error)", "Sync failing — \(error)"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            }
            .font(.caption2)
            .foregroundStyle(.orange)
            .frame(maxWidth: 260, alignment: .trailing)
            .help(error)
        } else if let at = relay.lastSyncAt {
            Label {
                // Split so the relative date keeps its live-updating Text style
                // while both languages get their own word order.
                Text("\(L("동기화", "Synced")) \(at, style: .relative)\(L(" 전", " ago"))")
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - AI usage meter

private struct AIUsageMeter: View {
    let snapshot: AIUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(L("AI 사용량", "AI Usage"), systemImage: "gauge.medium")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text(snapshot.updatedLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
            }

            HStack(spacing: 8) {
                ForEach(snapshot.items) { item in
                    UsagePill(item: item)
                }
            }
        }
        .frame(height: 62)
    }
}

private struct UsagePill: View {
    let item: AIUsageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.tint)
                    .frame(width: 6, height: 6)
                Text(item.name)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.connectionLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }
            Text(item.weeklyLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Text(item.remainingLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct AIUsageItem: Identifiable {
    let id: String
    let name: String
    let connectionLabel: String
    let weeklyLabel: String
    let remainingLabel: String
    let tint: Color
}

private struct AIUsageSnapshot {
    var items: [AIUsageItem]
    var updatedAt: Date?

    static let loading = AIUsageSnapshot(
        items: [
            AIUsageItem(id: "loading-codex", name: "Codex", connectionLabel: L("확인 중", "checking"), weeklyLabel: L("7일 사용량 ...", "7d usage ..."), remainingLabel: L("한도 확인 중", "quota pending"), tint: .white.opacity(0.45)),
            AIUsageItem(id: "loading-claude", name: "Claude", connectionLabel: L("확인 중", "checking"), weeklyLabel: L("7일 사용량 ...", "7d usage ..."), remainingLabel: L("잔액 확인 중", "balance pending"), tint: .white.opacity(0.45)),
        ],
        updatedAt: nil
    )

    var updatedLabel: String {
        guard let updatedAt else { return L("새로고침 중", "refreshing") }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return L("\(formatter.string(from: updatedAt)) 업데이트",
                 "updated \(formatter.string(from: updatedAt))")
    }

    static func load() async -> AIUsageSnapshot {
        let codex = LocalAIUsageReader.codexUsage()
        let apiUsage = LocalAIUsageReader.apiUsage()
        return AIUsageSnapshot(
            items: [
                AIUsageItem(
                    id: "codex",
                    name: "Codex",
                    connectionLabel: codex.isAuthenticated ? L("인증됨", "auth") : L("인증 없음", "no auth"),
                    weeklyLabel: codex.weeklyTokens > 0
                        ? L("\(Self.compact(codex.weeklyTokens)) 토큰 / 7일", "\(Self.compact(codex.weeklyTokens)) tok / 7d")
                        : L("로컬 기록 없음 / 7일", "no local tokens / 7d"),
                    remainingLabel: L("남은 한도는 비공개", "remaining hidden by auth"),
                    tint: codex.isAuthenticated ? ArcaTheme.idle : .white.opacity(0.35)
                ),
                AIUsageItem(
                    id: "claude",
                    name: "Claude",
                    connectionLabel: apiUsage.hasAnthropicKey ? L("API 키", "API key") : L("키 없음", "no key"),
                    weeklyLabel: apiUsage.anthropicTokens > 0
                        ? L("\(Self.compact(apiUsage.anthropicTokens)) 토큰 / 7일", "\(Self.compact(apiUsage.anthropicTokens)) tok / 7d")
                        : L("ARCA 기록 없음 / 7일", "no ARCA log / 7d"),
                    remainingLabel: L("잔액은 API 연결 필요", "billing balance needs API"),
                    tint: apiUsage.hasAnthropicKey ? .orange : .white.opacity(0.35)
                ),
                AIUsageItem(
                    id: "openai",
                    name: "OpenAI",
                    connectionLabel: apiUsage.hasOpenAIKey ? L("API 키", "API key") : L("키 없음", "no key"),
                    weeklyLabel: apiUsage.openAITokens > 0
                        ? L("\(Self.compact(apiUsage.openAITokens)) 토큰 / 7일", "\(Self.compact(apiUsage.openAITokens)) tok / 7d")
                        : L("ARCA 기록 없음 / 7일", "no ARCA log / 7d"),
                    remainingLabel: L("잔액은 API 연결 필요", "billing balance needs API"),
                    tint: apiUsage.hasOpenAIKey ? .green : .white.opacity(0.35)
                ),
            ],
            updatedAt: Date()
        )
    }

    private static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private enum LocalAIUsageReader {
    struct CodexUsage {
        var isAuthenticated: Bool
        var weeklyTokens: Int
    }

    struct APIUsage {
        var hasAnthropicKey: Bool
        var hasOpenAIKey: Bool
        var anthropicTokens: Int
        var openAITokens: Int
    }

    static func codexUsage(now: Date = Date()) -> CodexUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".codex/auth.json")
        let sessionsURL = home.appendingPathComponent(".codex/sessions")
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return CodexUsage(
            isAuthenticated: FileManager.default.fileExists(atPath: authURL.path),
            weeklyTokens: sumCodexTokens(in: sessionsURL, since: cutoff)
        )
    }

    static func apiUsage(now: Date = Date()) -> APIUsage {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logURL = home
            .appendingPathComponent("Library/Application Support/ARCA", isDirectory: true)
            .appendingPathComponent("ai-usage.jsonl")
        let totals = sumAPITokens(in: logURL, since: cutoff)
        return APIUsage(
            hasAnthropicKey: hasKey(.anthropic, environmentName: "ANTHROPIC_API_KEY"),
            hasOpenAIKey: hasKey(.openAI, environmentName: "OPENAI_API_KEY"),
            anthropicTokens: totals["anthropic"] ?? 0,
            openAITokens: totals["openai"] ?? 0
        )
    }

    private static func hasKey(_ kind: ApiKeyKind, environmentName: String) -> Bool {
        if KeychainStore.get(kind)?.isEmpty == false { return true }
        return ProcessInfo.processInfo.environment[environmentName]?.isEmpty == false
    }

    private static func sumCodexTokens(in directory: URL, since cutoff: Date) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified >= cutoff else { continue }
            total += sumTokens(inJSONLLinesAt: url)
        }
        return total
    }

    private static func sumAPITokens(in file: URL, since cutoff: Date) -> [String: Int] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var totals: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let provider = json["provider"] as? String,
                  let timestamp = json["timestamp"] as? String,
                  let date = ISO8601DateFormatter().date(from: timestamp),
                  date >= cutoff
            else { continue }
            let tokens = (json["inputTokens"] as? Int ?? 0) + (json["outputTokens"] as? Int ?? 0)
            totals[provider, default: 0] += tokens
        }
        return totals
    }

    private static func sumTokens(inJSONLLinesAt file: URL) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        var total = 0
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            total += sumUsageTokens(in: json)
        }
        return total
    }

    private static func sumUsageTokens(in value: Any) -> Int {
        if let dict = value as? [String: Any] {
            var total = 0
            if let usage = dict["usage"] as? [String: Any] {
                if let explicit = usage["total_tokens"] as? Int { total += explicit }
                else {
                    total += usage["input_tokens"] as? Int ?? 0
                    total += usage["output_tokens"] as? Int ?? 0
                    total += usage["cached_input_tokens"] as? Int ?? 0
                }
            }
            for child in dict.values {
                total += sumUsageTokens(in: child)
            }
            return total
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + sumUsageTokens(in: $1) }
        }
        return 0
    }
}

// MARK: - Chat column

private struct ChatLogColumn: View {
    let agent: NotchAgent
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatLogEntry.createdAt, order: .forward) private var log: [ChatLogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BriefingCard(compact: true)
                .padding(.top, 6)
            HStack {
                Label(L("대화", "Chat"), systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    agent.startBlankChat()
                } label: {
                    Label(L("새 대화", "New chat"), systemImage: "plus.bubble")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.arcaPress)
                .foregroundStyle(ArcaTheme.idle)
            }
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(log.suffix(40)) { entry in
                            LogRow(entry: entry).id(entry.persistentModelID)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .onAppear {
                    if let last = log.last { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
                }
            }
            .overlay {
                if log.isEmpty {
                    Text(L("아직 대화가 없어요.\n스크린샷을 노치에 끌어다 놓거나,\n새 대화를 시작해 보세요.",
                           "No conversations yet.\nDrag a screenshot onto the notch,\nor start a new chat."))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.trailing, 12)
    }
}

private struct LogRow: View {
    let entry: ChatLogEntry
    private var isUser: Bool { entry.roleRaw == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 30) }
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(isUser ? .white : .white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    isUser ? AnyShapeStyle(ArcaTheme.idle.opacity(0.85)) : AnyShapeStyle(.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 30) }
        }
    }
}

// MARK: - Zone toggle

private struct ZoneToggle: View {
    @Bindable var zone: ZoneEngine

    var body: some View {
        Button {
            if zone.isActive { zone.stop() } else { zone.start() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: zone.isActive ? "moon.stars.fill" : "moon.stars")
                Text(zone.isActive ? L("ZONE 종료", "End ZONE") : "ZONE")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(zone.isActive ? AnyShapeStyle(ArcaTheme.idle) : AnyShapeStyle(.white.opacity(0.12)),
                        in: Capsule())
        }
        .buttonStyle(.arcaPress)
        .help(zone.isActive
              ? L("포커스 모드를 끝내고 리포트 받기", "End focus mode and get the report")
              : L("포커스 모드 시작 — 방해는 ARCA가 막아요", "Start focus mode — ARCA guards interruptions"))
    }
}
#endif
