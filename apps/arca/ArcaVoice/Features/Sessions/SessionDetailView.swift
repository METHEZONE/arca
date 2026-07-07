import SwiftUI
import SwiftData
import ArcaVoiceKit

struct SessionDetailView: View {
    let session: RecordingSession

    private var sortedSegments: [StoredSegment] {
        session.segments.sorted { $0.start < $1.start }
    }

    private var speakerColorMap: [String: Color] {
        var map: [String: Color] = [:]
        var index = 0
        for segment in sortedSegments {
            let key = segment.speakerKey ?? segment.channelRaw
            if map[key] == nil {
                map[key] = ArcaTheme.speakerColors[index % ArcaTheme.speakerColors.count]
                index += 1
            }
        }
        return map
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

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

                notesSection
                transcriptSection
            }
            .padding()
        }
        .navigationTitle(session.title)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(session.createdAt, format: .dateTime.month().day().hour().minute())
            Text("·")
            Text(Duration.seconds(session.duration).formatted(.time(pattern: .minuteSecond)))
            if session.source == .macMeeting {
                Label("Video call", systemImage: "video.fill")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.12), in: Capsule())
            }
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var notesSection: some View {
        if let note = session.note {
            VStack(alignment: .leading, spacing: 12) {
                if let enhanced = note.enhancedMarkdown, !enhanced.isEmpty {
                    NoteCard(title: "My Notes (finalized)", icon: "sparkles", markdown: enhanced)
                } else if !note.roughMarkdown.isEmpty {
                    NoteCard(title: "My Notes", icon: "square.and.pencil", markdown: note.roughMarkdown)
                }
                if let summary = note.summaryMarkdown, !summary.isEmpty {
                    NoteCard(title: "Meeting Summary", icon: "doc.text.fill", markdown: summary)
                }
                if let data = note.decisionsJSON,
                   let decisions = try? JSONDecoder().decode([String].self, from: data),
                   !decisions.isEmpty {
                    NoteCard(title: "Decisions", icon: "checkmark.seal.fill",
                             markdown: decisions.map { "• \($0)" }.joined(separator: "\n"))
                }
                if let data = note.actionItemsJSON,
                   let items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data),
                   !items.isEmpty {
                    NoteCard(title: "Action Items", icon: "flag.fill",
                             markdown: items.map { item in
                                 var line = "• \(item.text)"
                                 if let assignee = item.assigneeName { line += " — \(assignee)" }
                                 return line
                             }.joined(separator: "\n"))
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if !sortedSegments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label("Transcript", systemImage: "waveform")
                    .font(.headline)

                ForEach(sortedSegments, id: \.persistentModelID) { segment in
                    TranscriptRow(
                        segment: segment,
                        color: speakerColorMap[segment.speakerKey ?? segment.channelRaw] ?? .secondary
                    )
                }
            }
        } else if session.state == .ready {
            ContentUnavailableView("Transcript is empty", systemImage: "waveform.slash")
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(segment.speakerKey ?? (segment.channelRaw == "microphone" ? "Me" : "Other"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    Text(Duration.seconds(segment.start).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if !segment.isFinal {
                        Text("Live")
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
