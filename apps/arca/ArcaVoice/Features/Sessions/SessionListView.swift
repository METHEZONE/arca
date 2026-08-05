import SwiftUI
import SwiftData
import ArcaVoiceKit

struct SessionListView: View {
    @Binding var selection: RecordingSession?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingSession.createdAt, order: .reverse)
    private var sessions: [RecordingSession]

    /// Recordings whose transcript is missing while their audio is still here.
    /// Recomputed on each render off the query, so it clears itself as the
    /// rebuilds land instead of needing its own invalidation.
    private var recoverable: [RecordingSession] {
        sessions
            .filter { $0.state != .recording && $0.state != .processing }
            .filter { $0.segments.isEmpty }
            .filter(FinalPassRunner.hasRecoverableAudio)
    }

    var body: some View {
        List(selection: $selection) {
            if !recoverable.isEmpty {
                recoveryBanner
            }
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
                // Copy without opening the record — the library is where you go
                // when you already know which note you want.
                .contextMenu {
                    Button {
                        ArcaClipboard.copy(SessionClipboardText.markdown(for: session))
                    } label: {
                        Label(L("회의록 복사", "Copy notes"), systemImage: "doc.on.doc")
                    }
                    Button {
                        ArcaClipboard.copy(SessionClipboardText.transcript(for: session))
                    } label: {
                        Label(L("전사 복사", "Copy transcript"), systemImage: "text.alignleft")
                    }
                    .disabled(session.segments.isEmpty)
                }
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
            if sessions.isEmpty && recoverable.isEmpty {
                ContentUnavailableView(
                    L("아직 녹음이 없어요", "No recordings yet"),
                    systemImage: "waveform.badge.mic",
                    description: Text(L("녹음하면 여기에 모여요.", "Recordings you make will show up here."))
                )
            }
        }
    }

    /// Offers to rebuild transcripts that went missing while their audio stayed.
    ///
    /// Deliberately a button rather than something that fires on its own: the
    /// audio isn't going anywhere, and re-transcribing hours of it costs real
    /// money, so the minutes are quoted up front and the decision stays with the
    /// person paying. The banner disappears by itself as the rebuilds land.
    private var recoveryBanner: some View {
        let records = recoverable
        let minutes = max(1, Int((FinalPassRunner.billableAudioSeconds(records) / 60).rounded()))
        let engine = EngineFactory.transcriptionEngine
        return VStack(alignment: .leading, spacing: 8) {
            Label(L("전사가 비어 있는 녹음 \(records.count)개 — 오디오는 그대로 있어요",
                    "\(records.count) recordings have no transcript — the audio is still here"),
                  systemImage: "arrow.trianglehead.2.clockwise")
                .font(.headline)

            // The cost sentence changes with the engine, because "about 400
            // minutes" means something very different when it's free.
            Text(engine == .localFree
                 ? L("오디오 약 \(minutes)분을 기기에서 다시 전사해요 — 비용 0원, 네트워크 없이. 시간은 좀 걸려요.",
                     "About \(minutes) min of audio, re-transcribed on this Mac — free, no network. It takes a while.")
                 : L("오디오 약 \(minutes)분을 클라우드로 보내요 (채널 합산, 과금 기준).",
                     "About \(minutes) min of audio would go to the cloud (channels summed, which is what gets billed)."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(engine == .localFree
                       ? L("무료로 전부 복구", "Rebuild all, free")
                       : L("전부 복구하기", "Rebuild all")) {
                    FinalPassRunner.recoverAll(
                        context: modelContext,
                        ownerName: AppServices.shared.ownerName,
                        languageHints: TranscriptionPrefs.languageHints)
                }
                .buttonStyle(.borderedProminent)

                if engine == .localFree, EngineFactory.hasFinalPassKey {
                    Button(L("화자분리로 복구 (유료)", "Rebuild with speaker separation (paid)")) {
                        FinalPassRunner.recoverAll(
                            context: modelContext,
                            ownerName: AppServices.shared.ownerName,
                            languageHints: TranscriptionPrefs.languageHints,
                            engine: .cloudDiarized)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }
}
