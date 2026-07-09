import EventKit
import SwiftData
import SwiftUI
import ArcaVoiceKit

@MainActor
struct ActionItemsCard: View {
    let note: SessionNote
    let session: RecordingSession

    @Environment(\.modelContext) private var modelContext
    @State private var editing: EditingDraft?
    @State private var linkingIndices: Set<Int> = []
    @State private var calendarErrors: [Int: String] = [:]

    private var ownerName: String {
        let stored = UserDefaults.standard.string(forKey: "ownerName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false ? stored! : "Me"
    }

    private var items: [MeetingNotes.ActionItem] {
        guard let data = note.actionItemsJSON,
              let decoded = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) else {
            return []
        }
        return decoded
    }

    private var groupedItems: [ActionItemGroup] {
        let indexed = items.enumerated().map { ActionItemEntry(index: $0.offset, item: $0.element) }
        let owner = indexed.filter { isOwner($0.item.assigneeName) }
        let unassigned = indexed.filter { normalized($0.item.assigneeName) == nil }
        let names = Set(indexed.compactMap { entry -> String? in
            guard let name = normalized(entry.item.assigneeName), !isOwner(name) else { return nil }
            return name
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var groups: [ActionItemGroup] = []
        if !owner.isEmpty {
            groups.append(ActionItemGroup(name: ownerName, kind: .owner, entries: owner))
        }
        for name in names {
            groups.append(ActionItemGroup(
                name: name,
                kind: .named,
                entries: indexed.filter { normalized($0.item.assigneeName) == name }
            ))
        }
        if !unassigned.isEmpty {
            groups.append(ActionItemGroup(name: "미지정", kind: .unassigned, entries: unassigned))
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Action Items", systemImage: "flag.fill")
                .font(.headline)

            ForEach(groupedItems) { group in
                groupView(group)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .popover(item: $editing) { draft in
            ActionItemEditor(
                draft: draft,
                onCancel: { editing = nil },
                onSave: saveEditedItem
            )
            .frame(minWidth: 300)
            .padding()
        }
    }

    private func groupView(_ group: ActionItemGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color(for: group.name))
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(group.entries.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            if group.kind == .owner, group.entries.contains(where: { $0.item.todoTaskUID == nil }) {
                ownerPrompt(entries: group.entries)
            }

            ForEach(group.entries, id: \.index) { entry in
                itemRow(entry)
            }
        }
    }

    private func ownerPrompt(entries: [ActionItemEntry]) -> some View {
        let pending = entries.filter { $0.item.todoTaskUID == nil }
        return HStack(spacing: 8) {
            Text("데드라인과 투두를 추가할까요?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("모두 추가") {
                for entry in pending {
                    linkItem(at: entry.index)
                }
            }
            .buttonStyle(.borderless)
            .disabled(pending.allSatisfy { linkingIndices.contains($0.index) })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func itemRow(_ entry: ActionItemEntry) -> some View {
        let item = entry.item
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(color(for: item.assigneeName ?? "미지정"))
                    .frame(width: 14)
                Text(item.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let due = item.due {
                    dueChip(due)
                }
                if isOwner(item.assigneeName), item.todoTaskUID == nil {
                    Button("추가") {
                        linkItem(at: entry.index)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(linkingIndices.contains(entry.index))
                }
                Button {
                    editing = EditingDraft(index: entry.index, item: item)
                } label: {
                    Image(systemName: "pencil.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Edit action item")
            }

            if item.todoTaskUID != nil {
                Label("투두 등록됨", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let message = calendarErrors[entry.index] {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func dueChip(_ due: Date) -> some View {
        Label {
            Text(due, format: .dateTime.month().day())
        } icon: {
            Image(systemName: "calendar")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private func saveEditedItem(_ draft: EditingDraft) {
        var next = items
        guard next.indices.contains(draft.index) else { return }
        next[draft.index].text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        next[draft.index].assigneeName = normalized(draft.assigneeName)
        next[draft.index].due = draft.hasDue ? draft.due : nil
        save(next)
        editing = nil
    }

    private func linkItem(at index: Int) {
        guard !linkingIndices.contains(index) else { return }
        linkingIndices.insert(index)
        calendarErrors[index] = nil

        Task { @MainActor in
            var next = items
            guard next.indices.contains(index), next[index].todoTaskUID == nil else {
                linkingIndices.remove(index)
                return
            }

            let item = next[index]
            let detail = taskDetail(for: item)
            let task = TodoTask(
                title: item.text,
                detail: detail,
                actionKind: .manual,
                source: "meeting:\(session.directoryName)"
            )
            task.urgency = urgency(for: item.due)
            modelContext.insert(task)
            next[index].todoTaskUID = task.uid.uuidString

            if let due = item.due {
                do {
                    let eventID = try await createCalendarEvent(title: item.text, due: due, description: detail)
                    next[index].calendarEventID = eventID
                } catch {
                    calendarErrors[index] = "캘린더 등록 실패: \(error.localizedDescription)"
                }
            }

            save(next)
            linkingIndices.remove(index)
        }
    }

    private func createCalendarEvent(title: String, due: Date, description: String) async throws -> String {
        if let calendar = ComposioCalendar.fromArcaConfig() {
            return try await calendar.createEvent(title: title, date: due, description: description)
        }
        return try await createEventWithEventKit(title: title, due: due, description: description)
    }

    private func createEventWithEventKit(title: String, due: Date, description: String) async throws -> String {
        let store = EKEventStore()
        let granted = try await store.requestWriteOnlyAccessToEvents()
        guard granted else { throw CalendarFallbackError.accessDenied }

        let start = ComposioCalendar.eventStart(for: due)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = description
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? UUID().uuidString
    }

    private func save(_ next: [MeetingNotes.ActionItem]) {
        note.actionItemsJSON = try? JSONEncoder().encode(next)
        session.touch()
        try? modelContext.save()
    }

    private func taskDetail(for item: MeetingNotes.ActionItem) -> String {
        var detail = "회의: \(session.title)"
        if let due = item.due {
            detail += "\n마감: \(due.formatted(date: .abbreviated, time: .omitted))"
        }
        return detail
    }

    private func urgency(for due: Date?) -> TaskUrgency {
        guard let due else { return .soon }
        let threshold = Date.now.addingTimeInterval(2 * 24 * 60 * 60)
        return due <= threshold ? .today : .soon
    }

    private func isOwner(_ name: String?) -> Bool {
        guard let normalizedName = normalized(name) else { return false }
        return normalizedName.caseInsensitiveCompare(ownerName) == .orderedSame
            || normalizedName.caseInsensitiveCompare("Me") == .orderedSame
    }

    private func normalized(_ name: String?) -> String? {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func color(for name: String) -> Color {
        let scalars = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return ArcaTheme.speakerColors[abs(scalars) % ArcaTheme.speakerColors.count]
    }
}

private struct ActionItemEntry {
    let index: Int
    let item: MeetingNotes.ActionItem
}

private struct ActionItemGroup: Identifiable {
    enum Kind { case owner, named, unassigned }

    let name: String
    let kind: Kind
    let entries: [ActionItemEntry]

    var id: String { "\(name)-\(kind)" }
}

private struct EditingDraft: Identifiable {
    let id = UUID()
    let index: Int
    var text: String
    var hasDue: Bool
    var due: Date
    var assigneeName: String

    init(index: Int, item: MeetingNotes.ActionItem) {
        self.index = index
        self.text = item.text
        self.hasDue = item.due != nil
        self.due = item.due ?? Date.now
        self.assigneeName = item.assigneeName ?? ""
    }
}

private struct ActionItemEditor: View {
    @State var draft: EditingDraft
    let onCancel: () -> Void
    let onSave: (EditingDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Action item", text: $draft.text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Toggle("Due date", isOn: $draft.hasDue)
            if draft.hasDue {
                DatePicker("Date", selection: $draft.due, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
            TextField("Assignee", text: $draft.assigneeName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private enum CalendarFallbackError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Calendar access denied"
        }
    }
}
