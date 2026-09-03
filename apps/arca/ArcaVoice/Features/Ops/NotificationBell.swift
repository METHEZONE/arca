#if os(macOS)
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Top-right bell: everything ARCA is waiting on you for. Proposals from
/// inbound mail (a meeting to add, a deadline to track) stack here until
/// answered; a fresh one also floats in as a toast for a few seconds. The
/// reply drafts in the right rail are counted too, so the badge is the one
/// number for "things that need a yes or no".
struct NotificationBell: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ActionProposal> { $0.stateRaw == "proposed" || $0.stateRaw == "failed" },
           sort: \ActionProposal.createdAt, order: .reverse) private var proposals: [ActionProposal]
    @Query(filter: #Predicate<ReplyProposal> { $0.stateRaw == "proposed" }) private var replies: [ReplyProposal]
    @State private var open = false
    @State private var engine = ProposalEngine.shared
    @State private var pasted = ""
    @State private var showPaste = false

    private var count: Int { proposals.count + replies.count }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
                    .symbolRenderingMode(count > 0 ? .multicolor : .monochrome)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(ArcaFace.ember, in: Capsule())
                        .offset(x: 8, y: -6)
                }
            }
        }
        .help(L("확인할 제안", "Things waiting on you"))
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("확인할 것", "Waiting on you"))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Spacer()
                    if engine.isWorking { ProgressView().controlSize(.small) }
                    Button {
                        Task { await AmbientOps.shared.harvest(context: context, force: true) }
                    } label: {
                        Label(L("메일 다시 읽기", "Re-read inbox"), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if proposals.isEmpty && replies.isEmpty {
                    Text(L("지금은 물어볼 게 없어요. 메일이 오면 일정·마감을 읽어서 여기서 물어볼게요.",
                           "Nothing to ask right now. When mail arrives, dates and deadlines show up here."))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(proposals) { proposal in
                            ProposalCard(proposal: proposal)
                        }
                        if !replies.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(ArcaFace.ember)
                                Text(L("답장 대기 \(replies.count)건 — 오른쪽 할 일 레일에서 승인", "\(replies.count) replies waiting — approve in the right rail"))
                                    .font(.callout)
                                Spacer()
                            }
                            .padding(12)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxHeight: 420)

                DisclosureGroup(isExpanded: $showPaste) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $pasted)
                            .font(.system(.callout, design: .rounded))
                            .frame(height: 110)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            if let error = engine.lastError {
                                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            }
                            Spacer()
                            Button(L("읽고 제안하기", "Read and propose")) {
                                let text = pasted
                                pasted = ""
                                Task { await engine.proposeFromPastedText(text, context: context) }
                            }
                            .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || engine.isWorking)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(L("메일이나 메시지 붙여넣어 시험", "Paste a mail or message to try"), systemImage: "doc.on.clipboard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(width: 420)
        }
    }
}

/// One proposal: what came in, what ARCA offers, and 네 / 아니요 / 기타.
struct ProposalCard: View {
    let proposal: ActionProposal
    var compact = false

    @Environment(\.modelContext) private var context
    @State private var engine = ProposalEngine.shared
    @State private var revising = false
    @State private var instruction = ""
    @State private var busy = false

    private var payload: [String: Any] { proposal.payload }
    private var tint: Color { proposal.kindRaw == "calendar" ? Color(hex: 0x4C8DFF) : Color(hex: 0xFFC531) }
    private var symbol: String { proposal.kindRaw == "calendar" ? "calendar.badge.plus" : "checklist" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.2)).frame(width: 34, height: 34)
                    Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceLine)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Text(proposal.summary.isEmpty ? proposal.subject : proposal.summary)
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text(proposal.question)
                .font(.system(compact ? .callout : .body, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)

            detailChips

            if proposal.stateRaw == "failed", let note = proposal.note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if revising {
                HStack(spacing: 8) {
                    TextField(L("어떻게 바꿀까요? 예: 30분 전으로, 제목은 'IR 리허설'", "How should it change? e.g. 30 min earlier"), text: $instruction)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendRevision)
                    Button(L("적용", "Apply"), action: sendRevision)
                        .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }

            HStack(spacing: 8) {
                Button {
                    busy = true
                    Task { await engine.accept(proposal, context: context); busy = false }
                } label: {
                    Label(proposal.stateRaw == "failed" ? L("다시 시도", "Retry") : L("네", "Yes"), systemImage: "checkmark")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(tint, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.arcaPress)
                .disabled(busy)

                Button {
                    engine.decline(proposal, context: context)
                } label: {
                    Text(L("아니요", "No"))
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.arcaPress)

                Button {
                    withAnimation(.spring(duration: 0.25)) { revising.toggle() }
                } label: {
                    Text(L("기타…", "Other…"))
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.white.opacity(revising ? 0.14 : 0.08), in: Capsule())
                }
                .buttonStyle(.arcaPress)

                Spacer()
                if busy || (engine.isWorking && revising) { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .background(Color(red: 0.08, green: 0.09, blue: 0.15).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.4)))
    }

    private var sourceLine: String {
        let who = proposal.sender.isEmpty ? "" : proposal.sender
        switch proposal.sourceRaw {
        case "gmail": return "📧 " + (who.isEmpty ? L("메일", "Mail") : who)
        case "slack": return "💬 Slack · " + who
        case "paste": return L("📋 붙여넣은 메시지", "📋 Pasted message")
        default: return who
        }
    }

    @ViewBuilder
    private var detailChips: some View {
        HStack(spacing: 6) {
            if proposal.kindRaw == "calendar" {
                if let start = ProposalEngine.parseDate(payload["start"] as? String) {
                    chip("calendar", start.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
                    let minutes = payload["durationMinutes"] as? Int ?? 60
                    chip("clock", L("\(minutes)분", "\(minutes) min"))
                }
                if let location = payload["location"] as? String, !location.isEmpty {
                    chip("mappin", location)
                }
            } else if let due = ProposalEngine.parseDate(payload["due"] as? String) {
                chip("flag", L("마감 \(due.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))",
                               "Due \(due.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))"))
            }
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(.caption, design: .rounded, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.07), in: Capsule())
            .lineLimit(1)
    }

    private func sendRevision() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        instruction = ""
        Task {
            await engine.revise(proposal, instruction: text, context: context)
            withAnimation { revising = false }
        }
    }
}

/// The newest unanswered proposal floats in top-right for a while, then
/// retreats into the bell. Answering it here is the same as in the bell.
struct ProposalToast: View {
    @Query(filter: #Predicate<ActionProposal> { $0.stateRaw == "proposed" },
           sort: \ActionProposal.createdAt, order: .reverse) private var proposals: [ActionProposal]
    @State private var dismissed: Set<UUID> = []

    private var current: ActionProposal? {
        proposals.first { !dismissed.contains($0.uid) && Date.now.timeIntervalSince($0.createdAt) < 90 }
    }

    var body: some View {
        if let proposal = current {
            ProposalCard(proposal: proposal, compact: true)
                .frame(width: 380)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                .overlay(alignment: .topTrailing) {
                    Button {
                        withAnimation { _ = dismissed.insert(proposal.uid) }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help(L("벨에 남겨두기", "Keep in the bell"))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: proposal.uid) {
                    try? await Task.sleep(for: .seconds(15))
                    withAnimation { _ = dismissed.insert(proposal.uid) }
                }
        }
    }
}
#endif
