import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The daily briefing: what to do, what to ask of people, what got done.
struct BriefingCard: View {
    @Environment(\.modelContext) private var context
    @State private var ops = AmbientOps.shared
    // Unused in the body; forces a re-render when the app language changes.
    @AppStorage(ArcaLang.defaultsKey) private var appLanguage = "system"
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ArcaFace(mood: ops.isBriefing ? .thinking : .idle,
                         size: 22, halo: false)
                    .frame(width: 24, height: 24)
                Text(L("오늘", "Today"))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Spacer()
                if let generated = ops.briefing?.generatedAt {
                    Text(generated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await ops.generateBriefing(context: context) }
                } label: {
                    Label(ops.briefing == nil ? L("브리핑 받기", "Brief me")
                                             : L("새로고침", "Refresh"),
                          systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(ArcaSkins.current.mid.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.arcaPress)
                .disabled(ops.isBriefing)
            }

            if ops.isBriefing {
                HStack(spacing: 8) {
                    ArcaFace(mood: .working, size: 18, halo: false)
                        .frame(width: 20, height: 20)
                    Text(L("하루를 살펴보고 있어요…", "Reading your day…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let briefing = ops.briefing {
                briefingBody(briefing)
            } else {
                Text(L("캘린더, 남은 할 일, 오늘의 세션 — 한 번만 누르면 하루를 정리해 드릴게요.",
                       "Calendar, open quests, today's sessions — one tap and I'll lay out your day."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = ops.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(compact ? 10 : 14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func briefingBody(_ briefing: AmbientOps.Briefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section(L("할 일", "Do"), items: briefing.today, symbol: "flag.fill",
                    tint: ArcaSkins.current.mid)
            if !briefing.asks.isEmpty {
                section(L("부탁할 일", "Ask"), items: briefing.asks, symbol: "person.2.fill",
                        tint: .blue)
            }
            if !briefing.done.isEmpty {
                section(L("끝난 일", "Done"), items: briefing.done, symbol: "checkmark.seal.fill",
                        tint: .green)
            }
        }
    }

    private func section(_ title: String, items: [String], symbol: String,
                         tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            ForEach(items.prefix(compact ? 4 : 6), id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(tint.opacity(0.8))
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.9))
                }
            }
        }
    }
}

/// One inbound ask, distilled into a question the user answers with one tap:
/// 네 (send it) / 아니요 (skip) / 기타 (type a direction, ARCA re-drafts).
struct ReplyApprovalRow: View {
    @Bindable var proposal: ReplyProposal
    @Environment(\.modelContext) private var context
    // Unused in the body, but its presence re-renders the row when the user
    // switches the app language in Settings.
    @AppStorage(ArcaLang.defaultsKey) private var appLanguage = "system"
    @State private var sending = false
    @State private var revising = false
    @State private var showDraft = false
    @State private var showDirection = false
    @State private var direction = ""

    private var questionText: String {
        if let question = proposal.question, !question.isEmpty { return question }
        let who = proposal.author.isEmpty ? proposal.channel : proposal.author
        return proposal.sourceRaw == "gmail"
            ? L("Reply to \(who)?", ko: "\(who)에게 회신할까요?")
            : L("Reply to \(who.isEmpty ? "Slack" : who)?", ko: "\(who.isEmpty ? "Slack" : who)에 답장할까요?")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: proposal.sourceRaw == "gmail" ? "envelope.fill" : "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(ArcaSkins.current.mid)
                    .padding(.top, 1)
                Text(questionText)
                    .font(.caption.weight(.bold))
                    .lineLimit(3)
                Spacer()
                Text(proposal.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if proposal.sourceRaw == "gmail" {
                // The literal send target — the question above is model text,
                // this is what actually goes on the envelope.
                Label(proposal.channel, systemImage: "arrow.turn.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let subject = proposal.subject, !subject.isEmpty {
                Text(subject)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(proposal.original)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let attachmentName = proposal.attachmentName {
                Label(attachmentName, systemImage: "paperclip")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ArcaSkins.current.mid.opacity(0.16), in: Capsule())
                    .foregroundStyle(ArcaSkins.current.mid)
                    .lineLimit(1)
            }

            Button {
                withAnimation(.spring(duration: 0.22)) { showDraft.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showDraft ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(L("Draft", ko: "답장 초안"))
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.arcaPress)
            .onAppear {
                // A card that ships a file must show what it's saying — the
                // draft is the user's last look before the attachment leaves.
                if proposal.attachmentPath != nil { showDraft = true }
            }
            if showDraft {
                TextField(L("Draft", ko: "초안"), text: $proposal.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(ArcaSkins.current.mid.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8))
            }

            if showDirection {
                HStack(spacing: 6) {
                    TextField(L("Tell ARCA what to change…", ko: "어떻게 할지 알려주세요…"),
                              text: $direction, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .lineLimit(1...3)
                        .padding(8)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit(applyDirection)
                    Button(action: applyDirection) {
                        if revising {
                            ArcaFace(mood: .working, size: 14, halo: false)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(direction.isEmpty
                                                 ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(ArcaSkins.current.mid))
                        }
                    }
                    .buttonStyle(.arcaPress)
                    .disabled(revising || sending || direction.isEmpty)
                }
            }

            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(duration: 0.22)) { showDirection.toggle() }
                } label: {
                    Text(L("Other…", ko: "기타…"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(showDirection ? ArcaSkins.current.mid : .secondary)
                }
                .buttonStyle(.arcaPress)
                .disabled(sending)
                Spacer()
                Button {
                    AmbientOps.shared.skip(proposal, context: context)
                } label: {
                    Text(L("No", ko: "아니요"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.arcaPress)
                .disabled(sending)
                Button {
                    sending = true
                    Task { @MainActor in
                        await AmbientOps.shared.approve(proposal, context: context)
                        sending = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if sending {
                            ArcaFace(mood: .working, size: 12, halo: false)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(L("Yes, send it", ko: "네, 보내줘"))
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(ArcaSkins.current.mid, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.arcaPress)
                .disabled(sending || revising || proposal.draft.isEmpty)
            }
        }
        .padding(10)
        .background(ArcaSkins.current.mid.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(ArcaSkins.current.mid.opacity(0.35), lineWidth: 1)
        }
    }

    private func applyDirection() {
        let text = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !revising, !sending else { return }
        revising = true
        Task { @MainActor in
            let applied = await AmbientOps.shared.revise(proposal, direction: text,
                                                         context: context)
            revising = false
            // On failure keep the typed direction so it isn't silently lost.
            guard applied else { return }
            direction = ""
            withAnimation(.spring(duration: 0.22)) {
                showDirection = false
                if proposal.stateRaw == "proposed" { showDraft = true }
            }
        }
    }
}
