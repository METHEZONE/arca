import SwiftUI
import ArcaVoiceKit

/// Who's in this meeting, gathered in the seconds before recording starts.
///
/// The names are worth collecting even though the default engine can't tell
/// voices apart: they go to the recognizer as expected vocabulary (which is what
/// stops Korean names from coming back as homophones), they stay on the record
/// as the attendee list, and they become the addresses the minutes go to.
@MainActor
@Observable
final class ParticipantPrep {
    private(set) var participants: [MeetingParticipant] = []
    /// What the user is currently typing. Committed on return or comma.
    var draft: String = ""
    private(set) var calendarEventTitle: String?
    private(set) var status: String?
    private(set) var isPulling = false

    var isEmpty: Bool { participants.isEmpty }

    /// The calendar meeting happening right now, if any — the iPhone's only way
    /// of knowing a recording is about to be a meeting rather than a memo.
    private(set) var detectedMeeting: CalendarEventInfo?
    @ObservationIgnored private var lastDetection: Date = .distantPast
    /// Sessions already offered a prep sheet, so declining one doesn't make it
    /// reappear on the next tap.
    @ObservationIgnored private var offeredEventIDs: Set<String> = []

    /// Looks for a meeting around now. Cheap to call repeatedly: it hits the
    /// network at most once every few minutes, and never blocks a tap — callers
    /// read `detectedMeeting`, which is whatever the last look found.
    func refreshDetectedMeeting() async {
        guard Date.now.timeIntervalSince(lastDetection) > 180 else { return }
        lastDetection = .now
        guard let reader = ComposioCalendarReader.fromArcaConfig() else { return }
        let now = Date.now
        let events = try? await reader.eventsOverlapping(
            start: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(4 * 3600))
        detectedMeeting = CalendarOverlapScorer.currentOrNext(in: events ?? [], at: now)
    }

    /// Whether tapping record should stop and ask who's here.
    ///
    /// Only for a meeting, only once per meeting: one-tap recording is the whole
    /// interaction on the phone, and putting a form in front of a voice memo
    /// would be a worse product than not knowing the names.
    func shouldOfferPrep() -> Bool {
        guard let event = detectedMeeting else { return false }
        return !offeredEventIDs.contains(event.id)
    }

    func markOffered() {
        if let event = detectedMeeting { offeredEventIDs.insert(event.id) }
    }

    func reset() {
        participants = []
        draft = ""
        calendarEventTitle = nil
        status = nil
        isPulling = false
    }

    /// Commits the draft. Splits on the separators people actually paste —
    /// a name list copied out of an invite arrives comma- or newline-joined.
    func commitDraft() {
        let separators = CharacterSet(charactersIn: ",;\n\t")
        let names = draft
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        participants = participants.merging(names.map { MeetingParticipant(name: $0, origin: .typed) })
        draft = ""
    }

    func remove(_ id: String) {
        participants.removeAll { $0.id == id }
    }

    /// Pulls attendees off the meeting that's running now, or about to.
    ///
    /// Works on both platforms — the calendar is the only participant source the
    /// iPhone has, since it can't see a meeting app's window.
    func pullFromCalendar(ownerName: String) async {
        guard let reader = ComposioCalendarReader.fromArcaConfig() else {
            status = L("캘린더가 연결되어 있지 않아요 (설정 → 커넥터).",
                       "No calendar connected yet (Settings → Connectors).")
            return
        }
        isPulling = true
        defer { isPulling = false }
        let now = Date.now
        do {
            // A window either side of now: the running meeting and the one about
            // to start both have to be candidates.
            let events = try await reader.eventsOverlapping(
                start: now.addingTimeInterval(-4 * 3600),
                end: now.addingTimeInterval(4 * 3600))
            guard let event = CalendarOverlapScorer.currentOrNext(in: events, at: now) else {
                status = L("지금 시간대에 잡힌 회의를 못 찾았어요.",
                           "No meeting found around now.")
                return
            }
            calendarEventTitle = event.title
            let pulled = event.attendees.compactMap { attendee -> MeetingParticipant? in
                let display = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                // Fall back to the local part of the address: "jane.kim@x.com"
                // reads as a person, the raw address reads as a machine.
                let name = (display?.isEmpty == false)
                    ? display!
                    : attendee.email.split(separator: "@").first.map(String.init) ?? attendee.email
                guard name.caseInsensitiveCompare(ownerName) != .orderedSame else { return nil }
                return MeetingParticipant(name: name, email: attendee.email, origin: .calendar)
            }
            guard !pulled.isEmpty else {
                status = L("\"\(event.title)\"에 참석자가 없어요.",
                           "\"\(event.title)\" has no attendees listed.")
                return
            }
            participants = participants.merging(pulled)
            status = nil
        } catch {
            status = L("캘린더를 못 읽었어요: \(error.localizedDescription)",
                       "Couldn't read the calendar: \(error.localizedDescription)")
        }
    }

    #if os(macOS)
    /// Reads the participant tiles off whatever meeting app is on screen.
    ///
    /// Mac only, and honest about why when it can't: this needs Screen Recording,
    /// and silently returning nothing would read as "nobody is in the meeting".
    func pullFromScreen(ownerName: String) async {
        guard MacPermission.screenRecording.isGranted else {
            status = L("화면에서 읽으려면 화면 기록 권한이 필요해요 (설정 → 권한).",
                       "Reading the screen needs Screen Recording permission (Settings → Permissions).")
            return
        }
        isPulling = true
        defer { isPulling = false }
        guard let roster = await MeetingRosterWatcher.readRosterNow() else {
            status = L("화면에서 참석자를 못 읽었어요. 회의 창이 보이게 두고 다시 눌러주세요.",
                       "Couldn't read participants from the screen. Bring the meeting window into view and try again.")
            return
        }
        let names = roster.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(ownerName) != .orderedSame }
        guard !names.isEmpty else {
            status = L("회의 화면에서 이름을 못 찾았어요.", "No names found on the meeting screen.")
            return
        }
        participants = participants.merging(names.map { MeetingParticipant(name: $0, origin: .screen) })
        status = nil
    }
    #endif
}

/// The pre-roll sheet: type names, or pull them, then start.
struct ParticipantPrepView: View {
    @Bindable var prep: ParticipantPrep
    let meetingLabel: String?
    let ownerName: String
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meetingLabel.map { L("\($0) 회의 — 누가 있나요?", "\($0) meeting — who's here?") }
                     ?? L("누가 있나요?", "Who's here?"))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text(L("이름을 넣어두면 전사에서 정확히 표기되고, 회의록에 참석자로 남고, 회의록을 바로 보낼 수 있어요.",
                       "Names entered here are spelled correctly in the transcript, recorded as attendees, and become who the minutes go to."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = prep.calendarEventTitle {
                    Label(title, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !prep.participants.isEmpty {
                ParticipantChips(participants: prep.participants) { prep.remove($0) }
            }

            TextField(L("이름 입력 후 return (쉼표로 여러 명)",
                        "Type a name and press return (commas for several)"),
                      text: $prep.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { prep.commitDraft() }

            HStack(spacing: 8) {
                Button {
                    Task { await prep.pullFromCalendar(ownerName: ownerName) }
                } label: {
                    Label(L("캘린더에서", "From calendar"), systemImage: "calendar.badge.plus")
                }
                #if os(macOS)
                Button {
                    Task { await prep.pullFromScreen(ownerName: ownerName) }
                } label: {
                    Label(L("회의 화면에서", "From meeting screen"), systemImage: "person.2.badge.gearshape")
                }
                #endif
                if prep.isPulling { ProgressView().controlSize(.small) }
            }
            .disabled(prep.isPulling)
            .buttonStyle(.bordered)

            if let status = prep.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                // Skipping must stay one click away: a meeting that already
                // started is worth more recorded-and-unlabelled than missed
                // while someone types names.
                Button(L("건너뛰고 녹음", "Skip and record")) {
                    prep.commitDraft()
                    onStart()
                }
                Spacer()
                Button(L("취소", "Cancel"), role: .cancel, action: onCancel)
                Button(L("녹음 시작", "Start recording")) {
                    prep.commitDraft()
                    onStart()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

/// The entered names, each removable.
private struct ParticipantChips: View {
    let participants: [MeetingParticipant]
    let onRemove: (String) -> Void

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(participants) { participant in
                HStack(spacing: 5) {
                    Image(systemName: icon(for: participant.origin))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(participant.name)
                        .font(.system(.callout, design: .rounded, weight: .medium))
                    Button {
                        onRemove(participant.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.secondary.opacity(0.14), in: Capsule())
                .help(participant.email ?? participant.name)
            }
        }
    }

    private func icon(for origin: MeetingParticipant.Origin) -> String {
        switch origin {
        case .typed: return "keyboard"
        case .calendar: return "calendar"
        case .screen: return "display"
        }
    }
}

/// Wraps chips onto as many lines as they need.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
