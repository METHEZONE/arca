import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The daily briefing: what to do, what to ask of people, what got done.
struct BriefingCard: View {
    @Environment(\.modelContext) private var context
    @State private var ops = AmbientOps.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ArcaFace(mood: ops.isBriefing ? .thinking : .idle,
                         size: 22, halo: false)
                    .frame(width: 24, height: 24)
                Text("Today")
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
                    Label(ops.briefing == nil ? "Brief me" : "Refresh",
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
                    Text("Reading your day…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let briefing = ops.briefing {
                briefingBody(briefing)
            } else {
                Text("Calendar, open quests, today's sessions — one tap and I'll lay out your day.")
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
            section("Do", items: briefing.today, symbol: "flag.fill",
                    tint: ArcaSkins.current.mid)
            if !briefing.asks.isEmpty {
                section("Ask", items: briefing.asks, symbol: "person.2.fill",
                        tint: .blue)
            }
            if !briefing.done.isEmpty {
                section("Done", items: briefing.done, symbol: "checkmark.seal.fill",
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

/// One drafted reply awaiting the human word. Approve → it flies.
struct ReplyApprovalRow: View {
    @Bindable var proposal: ReplyProposal
    @Environment(\.modelContext) private var context
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: proposal.sourceRaw == "gmail" ? "envelope.fill" : "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(ArcaSkins.current.mid)
                Text(proposal.sourceRaw == "gmail"
                     ? "\(proposal.channel)에게 이메일?"
                     : "Reply to \(proposal.author.isEmpty ? "Slack" : proposal.author)?")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Spacer()
                Text(proposal.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let subject = proposal.subject, !subject.isEmpty {
                Text(subject)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Text(proposal.original)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Draft", text: $proposal.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1...4)
                .padding(8)
                .background(ArcaSkins.current.mid.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Spacer()
                Button("Skip") {
                    AmbientOps.shared.skip(proposal, context: context)
                }
                .buttonStyle(.arcaPress)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        Text("Approve & send")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(ArcaSkins.current.mid, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.arcaPress)
                .disabled(sending || proposal.draft.isEmpty)
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
}
