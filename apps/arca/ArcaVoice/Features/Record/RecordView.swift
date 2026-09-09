import SwiftUI
import SwiftData
import ArcaVoiceKit
#if os(iOS)
import UIKit
#endif

/// The recording surface: live transcript on the left, the user's rough notes
/// on the right (stacked on iPhone). Volatile text breathes at lower opacity
/// and settles when finalized.
struct RecordView: View {
    @State private var idlePulse = false
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @AppStorage("ownerName") private var ownerName = "Me"
    var onSaved: (RecordingSession) -> Void = { _ in }

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 0) {
            switch coordinator.phase {
            case .idle:
                idleView
            case .recording, .stopping:
                recordingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(L("녹음 오류", "Recording error"), isPresented: .constant(coordinator.errorMessage != nil)) {
            Button(L("확인", "OK")) { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    private var idleView: some View {
        VStack(spacing: 22) {
            Spacer()
            recordButton
            VStack(spacing: 6) {
                Text(L("회의를 시작할까요?", "Ready to record?"))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(L("ARCA를 누르면 바로 듣기 시작해요. 끝나면 요약·결정·액션 아이템이 정리돼요.",
                       "Tap ARCA and it starts listening. When you stop, you get the summary, decisions and action items."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            #if os(macOS)
            Button {
                coordinator.includeSystemAudio.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: coordinator.includeSystemAudio ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(coordinator.includeSystemAudio ? ArcaSkins.current.mid : .secondary)
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                    Text(L("상대방 소리도 함께 (영상 통화·회의)", "Include the other side (calls & meetings)"))
                        .font(.system(.callout, design: .rounded, weight: .medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.white.opacity(coordinator.includeSystemAudio ? 0.10 : 0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(coordinator.includeSystemAudio ? ArcaSkins.current.mid.opacity(0.5) : .white.opacity(0.08)))
            }
            .buttonStyle(.arcaPress)
            .padding(.top, 4)
            #endif
            Spacer()
        }
        .padding()
    }

    private var recordingView: some View {
        VStack(spacing: 0) {
            header
            captureHealthBanner
            Divider()

            #if os(macOS)
            HSplitView {
                liveTranscript
                    .frame(minWidth: 320)
                notesEditor
                    .frame(minWidth: 240)
            }
            #else
            VStack(spacing: 0) {
                liveTranscript
                Divider()
                notesEditor
                    .frame(maxHeight: 200)
            }
            #endif
        }
    }

    /// A ticking timer over dead audio is the one thing this surface must never
    /// show: the user walks away believing the meeting is being recorded.
    private var isAudioFlowing: Bool { coordinator.captureHealth == .capturing }

    @ViewBuilder private var captureHealthBanner: some View {
        switch coordinator.captureHealth {
        case .capturing:
            EmptyView()
        case .interrupted(let reason):
            healthNotice(reason, systemImage: "pause.circle.fill", tint: .orange)
        case .stopped(let reason):
            healthNotice(reason, systemImage: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    private func healthNotice(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(isAudioFlowing ? ArcaTheme.recording : Color.orange)
                .frame(width: 10, height: 10)
                .opacity(isAudioFlowing ? pulseOpacity : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.3
                    }
                }
                // Re-animated with a finite curve, not assigned: a plain
                // assignment inherits the repeatForever and the loop survives
                // the view that started it.
                .onDisappear {
                    withAnimation(.easeOut(duration: 0.2)) { pulseOpacity = 1.0 }
                }

            if let startedAt = coordinator.startedAt {
                // Frozen while audio is down: the elapsed number would otherwise
                // keep climbing over silence that was never captured.
                Group {
                    if isAudioFlowing {
                        Text(startedAt, style: .timer)
                            .contentTransition(.numericText())
                    } else {
                        Text("일시중지")
                    }
                }
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(isAudioFlowing ? .primary : .secondary)
            }

            Spacer()

            Button {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                #endif
                Task {
                    if let saved = await coordinator.stop(modelContext: modelContext, ownerName: ownerName) {
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                        onSaved(saved)
                    }
                }
            } label: {
                Label(coordinator.phase == .stopping
                        ? L("마무리하고 있어요…", "Finishing up…")
                        : L("녹음 종료", "Stop recording"),
                      systemImage: "stop.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcaTheme.recording)
            .disabled(coordinator.phase == .stopping)
        }
        .padding()
    }

    @State private var pulseOpacity: Double = 1.0

    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(coordinator.displaySegments) { segment in
                        LiveSegmentRow(segment: segment)
                            .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: coordinator.displaySegments.last?.text) {
                if let lastID = coordinator.displaySegments.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var notesEditor: some View {
        @Bindable var coordinator = coordinator
        return VStack(alignment: .leading, spacing: 8) {
            Label(L("메모", "Rough notes"), systemImage: "square.and.pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.top, .horizontal])
            TextEditor(text: $coordinator.roughNotes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
        }
    }

    private var recordButton: some View {
        Button {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            Task {
                await coordinator.start(
                    modelContext: modelContext,
                    locale: TranscriptionPrefs.liveLocale,
                    languageHints: TranscriptionPrefs.languageHints)
            }
        } label: {
            ZStack {
                // Breathing ring, then ARCA itself — the companion is the button.
                Circle()
                    .strokeBorder(ArcaSkins.current.mid.opacity(0.35), lineWidth: 2)
                    .frame(width: 196, height: 196)
                    .scaleEffect(idlePulse ? 1.06 : 0.96)
                    .opacity(idlePulse ? 0.25 : 0.7)
                Circle()
                    .fill(ArcaSkins.current.mid.opacity(0.10))
                    .frame(width: 176, height: 176)
                ArcaFace(mood: .listening, size: 128, halo: true, followsPointer: true)
                    .frame(width: 150, height: 150)
                Label(L("녹음 시작", "Start"), systemImage: "waveform")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(ArcaSkins.current.mid, in: Capsule())
                    .foregroundStyle(.black)
                    .offset(y: 92)
            }
            .frame(width: 200, height: 220)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { idlePulse = true }
            }
        }
        .buttonStyle(.arcaPress)
    }
}

private struct LiveSegmentRow: View {
    let segment: LiveSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: segment.channel == .microphone ? "person.fill" : "person.2.fill")
                .font(.caption)
                .foregroundStyle(segment.channel == .microphone ? ArcaTheme.idle : .orange)
                .frame(width: 18)
                .padding(.top, 3)

            Text(segment.text)
                .font(.body)
                .opacity(segment.isVolatile ? 0.45 : 1.0)
                .animation(.easeOut(duration: 0.25), value: segment.isVolatile)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
