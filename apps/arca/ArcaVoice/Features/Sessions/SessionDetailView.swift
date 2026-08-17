import SwiftUI
import SwiftData
import ArcaVoiceKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct SessionDetailView: View {
    let session: RecordingSession

    @Environment(\.modelContext) private var modelContext
    @Query private var speakerRecords: [SpeakerRecord]
    @State private var participantOnlyAttendees: [CalendarAttendeeInfo] = []
    @State private var showingEmailSheet = false
    @State private var showingMeetingChat = false
    @State private var exportCache = TranscriptExportCache()
    #if os(macOS)
    @State private var isSyncingNotion = false
    #endif

    /// Everything the screen derives from the segment list, computed in ONE
    /// pass. These used to be separate computed vars that each re-sorted and
    /// re-scanned every segment (and the per-row email lookup was a linear
    /// scan of speaker records), which froze the view for long meetings.
    private struct TranscriptModel {
        var segments: [StoredSegment] = []
        var speakerNames: [String] = []
        var colorsByKey: [String: Color] = [:]
        var emailsByName: [String: String] = [:]
    }

    private func makeTranscriptModel() -> TranscriptModel {
        var model = TranscriptModel()
        model.segments = session.segments.sorted { $0.start < $1.start }

        var seen: Set<String> = []
        for segment in model.segments {
            let name = displayName(for: segment)
            if !seen.contains(name) {
                seen.insert(name)
                model.speakerNames.append(name)
            }
            let key = segment.speakerKey ?? segment.channelRaw
            if model.colorsByKey[key] == nil {
                model.colorsByKey[key] = SessionSpeakerStyle.color(for: name)
            }
        }
        for record in speakerRecords {
            if let email = record.email, !email.isEmpty {
                model.emailsByName[record.name.lowercased()] = email
            }
        }
        return model
    }

    private func participants(names: [String], emails: [String: String]) -> [SessionParticipant] {
        var output = names.map {
            SessionParticipant(name: $0, email: emails[$0.lowercased()], isSegmentSpeaker: true)
        }
        let existingKeys = Set(output.map(\.id))
        for attendee in participantOnlyAttendees {
            let name = attendee.displayName ?? attendee.email
            let participant = SessionParticipant(name: name, email: attendee.email, isSegmentSpeaker: false)
            if !existingKeys.contains(participant.id) {
                output.append(participant)
            }
        }
        return output
    }

    private var meetingNotes: MeetingNotes? {
        guard let note = session.note,
              let summary = note.summaryMarkdown,
              !summary.isEmpty else {
            return nil
        }
        let decisions: [String]
        if let data = note.decisionsJSON,
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            decisions = decoded
        } else {
            decisions = []
        }
        let actionItems: [MeetingNotes.ActionItem]
        if let data = note.actionItemsJSON,
           let decoded = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) {
            actionItems = decoded
        } else {
            actionItems = []
        }
        return MeetingNotes(
            title: session.title,
            summaryMarkdown: summary,
            decisions: decisions,
            actionItems: actionItems,
            enhancedNotesMarkdown: note.enhancedMarkdown
        )
    }

    var body: some View {
        let model = makeTranscriptModel()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header

                if !session.audioAssets.isEmpty || (session.source != .screenshot && session.source != .dayLog) {
                    SessionAudioBar(session: session)
                }

                if session.state == .processing {
                    ProgressView("High-quality transcription & speaker separation in progress…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }

                if let error = session.processingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                ParticipantsCard(
                    participants: participants(names: model.speakerNames, emails: model.emailsByName),
                    speakerNames: model.speakerNames,
                    sessionStart: session.createdAt,
                    sessionEnd: session.createdAt.addingTimeInterval(max(session.duration, 60)),
                    onSaveSpeaker: saveSpeaker(oldName:newName:email:),
                    onAddParticipantOnly: addParticipantOnly(name:email:)
                )

                notesSection
                transcriptSection(model: model)
            }
            .padding()
        }
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItem {
                Button {
                    showingMeetingChat = true
                } label: {
                    Label("이 회의와 대화", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            ToolbarItem {
                Button {
                    showingEmailSheet = true
                } label: {
                    Label("회의록 보내기", systemImage: "envelope")
                }
                .disabled(meetingNotes == nil)
            }
            ToolbarItem {
                Menu {
                    Button {
                        copyTranscript()
                    } label: {
                        Label("전사 복사", systemImage: "doc.on.doc")
                    }
                    if let files = exportCache.files(for: session) {
                        ShareLink(item: files.markdown) {
                            Label("Markdown으로 내보내기 (.md)", systemImage: "doc.richtext")
                        }
                        ShareLink(item: files.plainText) {
                            Label("텍스트로 내보내기 (.txt)", systemImage: "doc.plaintext")
                        }
                    }
                } label: {
                    Label("전사 공유", systemImage: "square.and.arrow.up")
                }
                .disabled(session.segments.isEmpty)
                .help("전사 내용을 복사하거나 파일로 내보내기")
            }
            #if os(macOS)
            // Also runs automatically after the quality pass when 커넥터's
            // auto-update is on; this is the backfill path for meetings recorded
            // before the database was linked.
            ToolbarItem {
                Button {
                    guard !isSyncingNotion else { return }
                    isSyncingNotion = true
                    Task {
                        defer { isSyncingNotion = false }
                        await NotionDBAutoSync.runManually(record: session)
                    }
                } label: {
                    Label("노션 DB 업데이트", systemImage: "tablecells")
                }
                .disabled(meetingNotes == nil || isSyncingNotion
                          || NotionDBAutoSync.databaseReference == nil)
                .help("이 회의 내용을 연결된 Notion 데이터베이스의 해당 행에 반영")
            }
            #endif
        }
        .sheet(isPresented: $showingMeetingChat) {
            MeetingChatSheet(session: session)
        }
        .sheet(isPresented: $showingEmailSheet) {
            if let notes = meetingNotes {
                // Recomputed here on purpose: the sheet opens rarely and the
                // model built in `body` isn't in scope inside the closure.
                let sheetModel = makeTranscriptModel()
                EmailMinutesSheet(
                    session: session,
                    notes: notes,
                    participants: participants(names: sheetModel.speakerNames,
                                               emails: sheetModel.emailsByName),
                    fallbackRecipient: AccountDefaults.string("summaryEmailRecipient") ?? "me@thezonebio.com"
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(session.createdAt, format: .dateTime.month().day().hour().minute())
            Text("·")
            Text(Duration.seconds(session.duration).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
            if session.source == .macMeeting {
                Label(session.meetingApp.map { "화상회의 · \($0)" } ?? "화상회의",
                      systemImage: "video.fill")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ArcaFace.ember.opacity(0.12), in: Capsule())
                    .foregroundStyle(ArcaFace.ember)
            }
            Spacer()
            Button {
                showingMeetingChat = true
            } label: {
                Label("이 회의와 대화", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ArcaFace.ember.opacity(0.14), in: Capsule())
                    .foregroundStyle(ArcaFace.ember)
            }
            .buttonStyle(.arcaPress)
            .help("이 회의록에 대해 ARCA와 대화")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var notesSection: some View {
        if let note = session.note {
            VStack(alignment: .leading, spacing: 12) {
                if let enhanced = note.enhancedMarkdown, !enhanced.isEmpty {
                    NoteCard(title: "내 메모 (정리됨)", icon: "sparkles", markdown: enhanced)
                } else if !note.roughMarkdown.isEmpty {
                    NoteCard(title: "내 메모", icon: "square.and.pencil", markdown: note.roughMarkdown)
                }
                if let summary = note.summaryMarkdown, !summary.isEmpty {
                    NoteCard(title: "회의 요약", icon: "doc.text.fill", markdown: summary)
                }
                if let data = note.decisionsJSON,
                   let decisions = try? JSONDecoder().decode([String].self, from: data),
                   !decisions.isEmpty {
                    NoteCard(title: "결정사항", icon: "checkmark.seal.fill",
                             markdown: decisions.map { "• \($0)" }.joined(separator: "\n"))
                }
                if let data = note.actionItemsJSON,
                   let items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data),
                   !items.isEmpty {
                    ActionItemsCard(note: note, session: session)
                }
            }
        }
    }

    /// Rows are emitted straight into the screen's single `LazyVStack` — no
    /// container of their own.
    ///
    /// They used to sit in a second, nested `LazyVStack`, which is not lazy:
    /// the outer stack has to size its child, so the inner one builds every
    /// row at once. A long meeting whose quality pass failed falls back to the
    /// raw live segments — thousands of them — and building all of those on the
    /// main thread while opening the session is what the watchdog was killing.
    /// Flat, only the visible rows are built.
    @ViewBuilder
    private func transcriptSection(model: TranscriptModel) -> some View {
        if !model.segments.isEmpty {
            Label("전사", systemImage: "waveform")
                .font(.headline)

            ForEach(model.segments, id: \.persistentModelID) { segment in
                TranscriptRow(
                    segment: segment,
                    color: model.colorsByKey[segment.speakerKey ?? segment.channelRaw] ?? .secondary,
                    email: model.emailsByName[displayName(for: segment).lowercased()],
                    speakerNames: model.speakerNames,
                    onSaveSpeaker: saveSpeaker(oldName:newName:email:)
                )
            }
        } else if session.state == .ready {
            ContentUnavailableView("전사 내용이 없어요", systemImage: "waveform.slash")
        }
    }

    private func displayName(for segment: StoredSegment) -> String {
        segment.speakerKey ?? (segment.channelRaw == "microphone" ? "Me" : "Other")
    }

    private func copyTranscript() {
        let text = session.transcriptPlainText()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    private func saveSpeaker(oldName: String, newName: String, email: String?) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        for segment in session.segments where displayName(for: segment) == oldName {
            segment.speakerKey = trimmedName
        }
        if let note = session.note,
           let data = note.actionItemsJSON,
           var items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) {
            var changed = false
            for index in items.indices where items[index].assigneeName == oldName {
                items[index].assigneeName = trimmedName
                changed = true
            }
            if changed {
                note.actionItemsJSON = try? JSONEncoder().encode(items)
            }
        }

        let record = speakerRecords.first {
            $0.name.caseInsensitiveCompare(oldName) == .orderedSame
                || $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        } ?? SpeakerRecord(name: trimmedName, colorHex: SessionSpeakerStyle.hexColor(for: trimmedName))
        record.name = trimmedName
        record.colorHex = record.colorHex.isEmpty ? SessionSpeakerStyle.hexColor(for: trimmedName) : record.colorHex
        record.email = trimmedEmail?.isEmpty == false ? trimmedEmail : nil
        if record.modelContext == nil {
            modelContext.insert(record)
        }

        session.touch()
        try? modelContext.save()
    }

    private func addParticipantOnly(name: String, email: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedEmail.isEmpty else { return }
        let attendee = CalendarAttendeeInfo(email: trimmedEmail, displayName: trimmedName)
        if !participantOnlyAttendees.contains(attendee) {
            participantOnlyAttendees.append(attendee)
        }

        let record = speakerRecords.first {
            $0.email?.caseInsensitiveCompare(trimmedEmail) == .orderedSame
                || $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        } ?? SpeakerRecord(name: trimmedName, colorHex: SessionSpeakerStyle.hexColor(for: trimmedName))
        record.name = trimmedName
        record.colorHex = record.colorHex.isEmpty ? SessionSpeakerStyle.hexColor(for: trimmedName) : record.colorHex
        record.email = trimmedEmail
        if record.modelContext == nil {
            modelContext.insert(record)
        }
        session.touch()
        try? modelContext.save()
    }
}

/// `ShareLink` needs a URL up front and `Menu` builds its content whenever the
/// view body runs, so the temp files are written once per transcript version
/// instead of on every redraw — a two-hour meeting is a few hundred KB.
@MainActor
private final class TranscriptExportCache {
    private var key: String?
    private var cached: (markdown: URL, plainText: URL)?

    func files(for session: RecordingSession) -> (markdown: URL, plainText: URL)? {
        let currentKey = "\(session.title)|\(session.segments.count)|\(session.updatedAt.timeIntervalSince1970)"
        if currentKey == key, let cached { return cached }

        let directory = FileManager.default.temporaryDirectory
        let stem = session.transcriptFileStem
        let markdown = directory.appendingPathComponent("\(stem).md")
        let plainText = directory.appendingPathComponent("\(stem).txt")
        do {
            try session.transcriptMarkdown().write(to: markdown, atomically: true, encoding: .utf8)
            try session.transcriptPlainText().write(to: plainText, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        key = currentKey
        cached = (markdown, plainText)
        return cached
    }
}

private struct NoteCard: View {
    let title: String
    let icon: String
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(LocalizedStringKey(markdown))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TranscriptRow: View {
    let segment: StoredSegment
    let color: Color
    let email: String?
    let speakerNames: [String]
    let onSaveSpeaker: (String, String, String?) -> Void

    @State private var editRequest: SpeakerEditRequest?
    @State private var hoveringSpeaker = false

    private var speakerName: String {
        segment.speakerKey ?? (segment.channelRaw == "microphone" ? "Me" : "Other")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Button {
                        editRequest = SpeakerEditRequest(
                            mode: .existing(oldName: speakerName),
                            name: speakerName,
                            email: email ?? "",
                            selectedSpeakerName: speakerName
                        )
                    } label: {
                        Text(speakerName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                            .underline(hoveringSpeaker, color: color)
                    }
                    .buttonStyle(.arcaPress)
                    #if os(macOS)
                    .onHover { hoveringSpeaker = $0 }
                    #endif
                    .popover(item: $editRequest) { request in
                        SpeakerAssignmentPopover(
                            request: request,
                            speakerNames: speakerNames,
                            onCancel: { editRequest = nil },
                            onSave: { updated in
                                let email = updated.email.trimmingCharacters(in: .whitespacesAndNewlines)
                                onSaveSpeaker(speakerName, updated.name, email.isEmpty ? nil : email)
                                editRequest = nil
                            }
                        )
                        .frame(minWidth: 320)
                        .padding()
                        .presentationCompactAdaptation(.sheet)
                    }
                    Text(Duration.seconds(segment.start).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if !segment.isFinal {
                        Text("실시간")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct EmailMinutesSheet: View {
    let session: RecordingSession
    let notes: MeetingNotes
    let participants: [SessionParticipant]
    let fallbackRecipient: String

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var extraEmails = ""
    @State private var isSending = false
    @State private var results: [EmailSendResult] = []
    @State private var errorMessage: String?

    private var options: [EmailRecipientOption]

    init(session: RecordingSession, notes: MeetingNotes,
         participants: [SessionParticipant], fallbackRecipient: String) {
        self.session = session
        self.notes = notes
        self.participants = participants
        self.fallbackRecipient = fallbackRecipient

        var options = participants.compactMap { participant -> EmailRecipientOption? in
            guard let email = participant.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else { return nil }
            return EmailRecipientOption(name: participant.name, email: email, isFallback: false)
        }
        let fallback = fallbackRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty,
           !options.contains(where: { $0.email.caseInsensitiveCompare(fallback) == .orderedSame }) {
            options.append(EmailRecipientOption(name: "요약 메일", email: fallback, isFallback: true))
        }
        self.options = options
        _selected = State(initialValue: Set(options.map(\.email)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("회의록 보내기", systemImage: "envelope.fill")
                    .font(.headline)
                Spacer()
                Button("닫기") { dismiss() }
            }

            if options.isEmpty {
                Text("이메일이 있는 참가자가 없습니다. 아래에 직접 추가할 수 있습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(options) { option in
                        Toggle(isOn: Binding(
                            get: { selected.contains(option.email) },
                            set: { isOn in
                                if isOn { selected.insert(option.email) }
                                else { selected.remove(option.email) }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Text(option.name)
                                Text(option.email)
                                    .foregroundStyle(.secondary)
                                if option.isFallback {
                                    Text("기본")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }

            TextField("추가 이메일 (쉼표로 구분)", text: $extraEmails)
                .textFieldStyle(.roundedBorder)

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { result in
                        HStack(spacing: 8) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .orange)
                            Text(result.recipient)
                                .font(.caption)
                            if let error = result.errorDescription, !result.success {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .disabled(isSending)
                Button {
                    send()
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("보내기")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSending || recipients.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private var recipients: [String] {
        let extra = extraEmails
            .split(separator: ",")
            .map(String.init)
        return ComposioEmailSender.normalizedRecipients(Array(selected) + extra)
    }

    private func send() {
        errorMessage = nil
        results = []
        guard let sender = ComposioEmailSender.fromArcaConfig() else {
            errorMessage = "Gmail 연결이 설정되어 있지 않습니다."
            return
        }
        isSending = true
        let title = session.title
        let date = session.createdAt
        let targetRecipients = recipients
        Task { @MainActor in
            results = await sender.sendSummary(to: targetRecipients, sessionTitle: title, notes: notes, date: date)
            isSending = false
        }
    }
}

private struct EmailRecipientOption: Identifiable {
    var id: String { email.lowercased() }
    var name: String
    var email: String
    var isFallback: Bool
}
