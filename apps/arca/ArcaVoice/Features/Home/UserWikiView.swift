import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Cross-platform on purpose. Nothing here is Mac-specific — the memories and
/// sessions it reads already sync between devices, so gating it to macOS meant
/// the iPhone was missing a section for no reason other than where it happened
/// to be written first.
struct UserWikiView: View {
    let ownerName: String
    let facts: [MemoryFact]
    let sessions: [RecordingSession]

    @State private var markdown = ""
    @State private var generatedAt: Double = 0
    @State private var isGenerating = false
    @State private var errorText: String?

    private var generatedDate: Date? {
        generatedAt > 0 ? Date(timeIntervalSince1970: generatedAt) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState
            } else {
                ScrollView {
                    Text(.init(markdown))
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: loadScopedWiki)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("\(ownerName) 위키", "\(ownerName)'s Wiki"))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(L("ARCA가 기록한 당신의 이야기", "Your story, as ARCA remembers it"))
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                if let generatedDate {
                    Text(L("마지막 생성 \(generatedDate.formatted(date: .abbreviated, time: .shortened))",
                           "Last generated \(generatedDate.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.38))
                }
            }
            Spacer()
            Button {
                generate()
            } label: {
                Label(markdown.isEmpty ? L("생성", "Generate") : L("다시 생성", "Regenerate"), systemImage: "sparkles")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(ArcaSkins.current.mid, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.arcaPress)
            .disabled(isGenerating)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ArcaFace(mood: isGenerating ? .thinking : .idle, size: 118, halo: true)
            Text(isGenerating
                 ? L("당신의 이야기를 엮는 중이에요…", "Weaving your story together…")
                 : L("아직 위키가 없어요. ARCA가 당신에 대해 알게 된 것들로 첫 페이지를 만들어볼까요?",
                     "No wiki yet. Want ARCA to write the first page from what it knows about you?"))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button {
                generate()
            } label: {
                Label(L("생성", "Generate"), systemImage: "book.closed.fill")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.arcaPress)
            .disabled(isGenerating)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generate() {
        guard !isGenerating else { return }
        guard let apiKey = KeychainStore.get(.anthropic), !apiKey.isEmpty else {
            errorText = L("Anthropic 키를 Settings에 추가하면 위키를 생성할 수 있어요.",
                          "Add your Anthropic key in Settings to generate your wiki.")
            return
        }
        isGenerating = true
        errorText = nil
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
        let memoryInputs = facts
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(200)
            .map { WikiGenerator.MemoryInput(text: $0.text, kind: $0.kindRaw, date: $0.createdAt) }
        let sessionInputs = sessions
            .sorted { $0.createdAt > $1.createdAt }
            .map { WikiGenerator.SessionInput(title: $0.title, date: $0.createdAt) }

        Task { @MainActor in
            defer { isGenerating = false }
            do {
                let generated = try await WikiGenerator(apiKey: apiKey, model: model)
                    .generate(ownerName: ownerName, memories: Array(memoryInputs), sessions: sessionInputs)
                markdown = generated
                AccountDefaults.set(generated, for: "userWikiMarkdown")
                generatedAt = Date.now.timeIntervalSince1970
                UserDefaults.standard.set(generatedAt, forKey: AccountDefaults.key("userWikiGeneratedAt"))
            } catch {
                errorText = UserFacingError.message(for: error)
            }
        }
    }

    private func loadScopedWiki() {
        markdown = AccountDefaults.string("userWikiMarkdown") ?? ""
        generatedAt = UserDefaults.standard.double(forKey: AccountDefaults.key("userWikiGeneratedAt"))
    }
}

/// Self-contained 위키 screen — fetches its own inputs so any surface can push it
/// without threading queries through. The Mac companion already has the facts and
/// sessions in hand and feeds `UserWikiView` directly.
struct UserWikiScreen: View {
    @Query(sort: \MemoryFact.createdAt, order: .reverse) private var facts: [MemoryFact]
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]

    var body: some View {
        UserWikiView(ownerName: AppServices.shared.ownerDisplayName,
                     facts: facts,
                     sessions: sessions)
            .background(ArcaTheme.spiritNight.ignoresSafeArea())
    }
}
