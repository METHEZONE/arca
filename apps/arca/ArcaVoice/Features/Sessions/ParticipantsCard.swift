import SwiftUI
import ArcaVoiceKit

struct SessionParticipant: Identifiable, Hashable {
    var id: String { email?.lowercased() ?? name.lowercased() }
    var name: String
    var email: String?
    var isSegmentSpeaker: Bool
}

struct SpeakerEditRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        case existing(oldName: String)
        case suggestion(attendee: CalendarAttendeeInfo)
    }

    let id = UUID()
    var mode: Mode
    var name: String
    var email: String
    var selectedSpeakerName: String?
}

struct ParticipantsCard: View {
    let participants: [SessionParticipant]
    let speakerNames: [String]
    let sessionStart: Date
    let sessionEnd: Date
    let onSaveSpeaker: (String, String, String?) -> Void
    let onAddParticipantOnly: (String, String) -> Void

    @State private var editRequest: SpeakerEditRequest?
    @State private var isFetching = false
    @State private var calendarError: String?
    @State private var suggestedEvent: CalendarEventInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Participants", systemImage: "person.2.fill")
                    .font(.headline)
                Spacer()
                Button {
                    fetchCalendarAttendees()
                } label: {
                    if isFetching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("캘린더에서 참석자 가져오기", systemImage: "calendar.badge.person.crop")
                    }
                }
                .disabled(isFetching)
            }

            if participants.isEmpty {
                Text("No speakers yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(participants) { participant in
                            Button {
                                editRequest = SpeakerEditRequest(
                                    mode: .existing(oldName: participant.name),
                                    name: participant.name,
                                    email: participant.email ?? "",
                                    selectedSpeakerName: participant.name
                                )
                            } label: {
                                participantChip(participant)
                            }
                            .buttonStyle(.arcaPress)
                        }
                    }
                }
            }

            if let suggestedEvent {
                VStack(alignment: .leading, spacing: 8) {
                    Text(suggestedEvent.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestedEvent.attendees, id: \.self) { attendee in
                                Button {
                                    editRequest = SpeakerEditRequest(
                                        mode: .suggestion(attendee: attendee),
                                        name: attendee.displayName ?? attendee.email,
                                        email: attendee.email,
                                        selectedSpeakerName: speakerNames.first
                                    )
                                } label: {
                                    suggestionChip(attendee)
                                }
                                .buttonStyle(.arcaPress)
                            }
                        }
                    }
                }
            }

            if let calendarError {
                Text(calendarError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .popover(item: $editRequest) { request in
            SpeakerAssignmentPopover(
                request: request,
                speakerNames: speakerNames,
                onCancel: { editRequest = nil },
                onSave: save
            )
            .frame(minWidth: 320)
            .padding()
        }
    }

    private func participantChip(_ participant: SessionParticipant) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(SessionSpeakerStyle.color(for: participant.name))
                .frame(width: 8, height: 8)
            Text(participant.name)
                .font(.caption.weight(.semibold))
            if participant.email != nil {
                Image(systemName: "envelope.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.opacity(0.75), in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
    }

    private func suggestionChip(_ attendee: CalendarAttendeeInfo) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(attendee.displayName ?? attendee.email)
                    .font(.caption.weight(.semibold))
                Text(attendee.email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.green.opacity(0.08), in: Capsule())
    }

    private func fetchCalendarAttendees() {
        calendarError = nil
        suggestedEvent = nil
        isFetching = true

        Task { @MainActor in
            defer { isFetching = false }
            guard let reader = ComposioCalendarReader.fromArcaConfig() else {
                calendarError = "Google Calendar 연결이 설정되어 있지 않습니다."
                return
            }
            do {
                let events = try await reader.eventsOverlapping(start: sessionStart, end: sessionEnd)
                guard let best = CalendarOverlapScorer.bestEvent(overlapping: events, start: sessionStart, end: sessionEnd) else {
                    calendarError = "겹치는 캘린더 일정을 찾지 못했습니다."
                    return
                }
                suggestedEvent = best
                if best.attendees.isEmpty {
                    calendarError = "선택된 일정에 참석자 이메일이 없습니다."
                }
            } catch {
                calendarError = error.localizedDescription
            }
        }
    }

    private func save(_ request: SpeakerEditRequest) {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = request.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        switch request.mode {
        case .existing(let oldName):
            onSaveSpeaker(oldName, name, email.isEmpty ? nil : email)
        case .suggestion:
            if let selected = request.selectedSpeakerName, !selected.isEmpty {
                onSaveSpeaker(selected, name, email.isEmpty ? nil : email)
            } else if !email.isEmpty {
                onAddParticipantOnly(name, email)
            }
        }
        editRequest = nil
    }
}

struct SpeakerAssignmentPopover: View {
    @State var request: SpeakerEditRequest
    let speakerNames: [String]
    let onCancel: () -> Void
    let onSave: (SpeakerEditRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("화자 지정")
                .font(.headline)

            if case .suggestion = request.mode {
                Picker("연결할 화자", selection: Binding(
                    get: { request.selectedSpeakerName ?? "" },
                    set: { request.selectedSpeakerName = $0.isEmpty ? nil : $0 }
                )) {
                    Text("참가자만 추가").tag("")
                    ForEach(speakerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            TextField("이름", text: $request.name)
                .textFieldStyle(.roundedBorder)
            TextField("이메일", text: $request.email)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("저장") { onSave(request) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
