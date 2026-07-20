#if os(iOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The "instant context" sheet: shown right after the user shares something
/// into ARCA. Reads the screen, offers concrete actions, and lets the user
/// steer with a follow-up instruction or jump into full chat.
struct ContextView: View {
    let item: SharedInbox.Item
    var onOpenChat: (SharedInbox.Item) -> Void
    var onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var engine = ContextEngine()
    @State private var thumbnail: UIImage?
    @State private var visibleSuggestions: [ContextEngine.Suggestion] = []
    @State private var runningIDs: Set<UUID> = []
    @State private var results: [UUID: String] = [:]
    @State private var instructionText = ""
    @State private var directReply: String?
    @State private var isAnsweringDirect = false
    @State private var analysisLogged = false

    private static let ember = Color(red: 1.0, green: 0.478, blue: 0.102)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    summarySection
                    if !visibleSuggestions.isEmpty {
                        suggestionsSection
                    }
                    instructionSection
                }
                .padding(20)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
        .background(
            LinearGradient(colors: [ArcaFace.bodyTop, ArcaFace.bodyBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            if item.kind == .image, let url = SharedInbox.imageURL(for: item) {
                thumbnail = UIImage(contentsOfFile: url.path)
            }
            RecordingActivityController.shared.note("Reading what you shared…", for: 45)
            await engine.analyze(item: item)
        }
        .onChange(of: engine.isAnalyzing) { wasAnalyzing, nowAnalyzing in
            if wasAnalyzing && !nowAnalyzing {
                revealSuggestions()
                persistAnalysis()
            }
        }
    }

    /// Every share leaves a trace: the item + ARCA's read land in the chat
    /// log (one conversation per share), so history survives this sheet.
    private var shareConversationId: String { "share-\(item.id.uuidString)" }

    private func log(role: String, text: String, imageData: Data? = nil) {
        guard !text.isEmpty else { return }
        modelContext.insert(ChatLogEntry(role: role, text: text,
                                         conversationId: shareConversationId,
                                         imageData: imageData))
        try? modelContext.save()
    }

    private func persistAnalysis() {
        guard !analysisLogged else { return }
        analysisLogged = true
        let jpeg = thumbnail?.jpegData(compressionQuality: 0.6)
        log(role: "user", text: "📎 \(kindCaption)" + (item.text.map { ": \($0.prefix(200))" } ?? ""),
            imageData: jpeg)
        if let error = engine.error {
            log(role: "assistant", text: "Couldn't read this: \(error)")
            RecordingActivityController.shared.note("Couldn't read that share", for: 8)
        } else {
            log(role: "assistant", text: engine.summary)
            let count = engine.suggestions.count
            RecordingActivityController.shared.note(
                count > 0 ? "\(count) action\(count == 1 ? "" : "s") ready" : "Read it — open ARCA",
                for: 20)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            ArcaFace(mood: engine.isAnalyzing ? .thinking : .happy, size: 64, halo: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("Here's what I see")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(kindCaption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
    }

    private var kindCaption: String {
        switch item.kind {
        case .image: return "Shared screenshot"
        case .url: return "Shared link"
        case .text: return "Shared text"
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let error = engine.error {
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.red.opacity(0.9))
        } else if engine.isAnalyzing && engine.summary.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Reading the screen…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else if !engine.summary.isEmpty {
            Text(engine.summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(visibleSuggestions) { suggestion in
                SuggestionCard(
                    suggestion: suggestion,
                    ember: Self.ember,
                    isRunning: runningIDs.contains(suggestion.id),
                    result: results[suggestion.id],
                    onRun: { runSuggestion(suggestion) }
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
    }

    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Anything else I should know or do?", text: $instructionText, axis: .vertical)
                    .lineLimit(1...3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                Button(action: sendInstruction) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(instructionText.isEmpty ? Color.white.opacity(0.3) : Self.ember)
                }
                .disabled(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnsweringDirect)
            }
            if isAnsweringDirect {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Thinking…").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            } else if let directReply {
                Text(directReply)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                onOpenChat(item)
            } label: {
                Label("Open full chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .tint(Self.ember)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.35))
    }

    // MARK: - Actions

    private func revealSuggestions() {
        visibleSuggestions = []
        for (index, suggestion) in engine.suggestions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.08) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    visibleSuggestions.append(suggestion)
                }
            }
        }
    }

    private func runSuggestion(_ suggestion: ContextEngine.Suggestion) {
        guard !runningIDs.contains(suggestion.id), results[suggestion.id] == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        runningIDs.insert(suggestion.id)
        let instruction = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await engine.run(suggestion, context: modelContext,
                                           instruction: instruction.isEmpty ? nil : instruction)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                results[suggestion.id] = result
                runningIDs.remove(suggestion.id)
            }
            log(role: "assistant", text: "▸ \(suggestion.label) — \(result)")
            RecordingActivityController.shared.note(result, for: 15)
        }
    }

    private func sendInstruction() {
        let text = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        instructionText = ""
        isAnsweringDirect = true
        directReply = nil
        Task {
            let reply = await engine.answerDirect(text)
            withAnimation(.easeOut(duration: 0.2)) {
                directReply = reply
                isAnsweringDirect = false
            }
            log(role: "user", text: text)
            log(role: "assistant", text: reply)
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: ContextEngine.Suggestion
    let ember: Color
    let isRunning: Bool
    let result: String?
    let onRun: () -> Void

    private var iconName: String {
        switch suggestion.kind {
        case .calendar: return "calendar.badge.plus"
        case .task: return "checklist"
        case .plan: return "sparkles"
        case .replyDraft: return "text.bubble"
        case .note: return "note.text"
        }
    }

    var body: some View {
        Button(action: onRun) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result == nil ? iconName : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(result == nil ? ember : .green)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(result ?? suggestion.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(3)
                }
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(ember.opacity(result == nil ? 0.35 : 0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(result != nil || isRunning)
    }
}
#endif
