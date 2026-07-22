import SwiftUI
import SwiftData
import ArcaVoiceKit

struct SessionListView: View {
    @Binding var selection: RecordingSession?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingSession.createdAt, order: .reverse)
    private var sessions: [RecordingSession]

    var body: some View {
        List(selection: $selection) {
            ForEach(sessions) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(1)
                        if session.state == .processing {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(session.createdAt, format: .dateTime.month().day())
                        Text(Duration.seconds(session.duration).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                        if session.source == .macMeeting {
                            Image(systemName: "video.fill")
                        } else if session.source == .watchMemo {
                            Image(systemName: "applewatch")
                        } else if session.source == .dayLog {
                            Image(systemName: "sun.horizon.fill")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(session)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let session = sessions[index]
                    try? FileManager.default.removeItem(
                        at: SessionPaths.directory(for: session.directoryName))
                    modelContext.delete(session)
                }
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform.badge.mic",
                    description: Text("Recordings you make will show up here.")
                )
            }
        }
    }
}
