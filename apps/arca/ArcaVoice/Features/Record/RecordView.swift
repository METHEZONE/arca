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
        .alert("Recording error", isPresented: .constant(coordinator.errorMessage != nil)) {
            Button("OK") { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    private var idleView: some View {
        VStack(spacing: 28) {
            Spacer()
            recordButton
            Text("Tap to start recording")
                .font(.title3)
                .foregroundStyle(.secondary)

            #if os(macOS)
            Toggle(isOn: Binding(
                get: { coordinator.includeSystemAudio },
                set: { coordinator.includeSystemAudio = $0 }
            )) {
                Label("Also capture the other person's audio (video calls)", systemImage: "speaker.wave.2.fill")
            }
            .toggleStyle(.checkbox)
            .padding(.top, 8)
            #endif
            Spacer()
        }
        .padding()
    }

    private var recordingView: some View {
        VStack(spacing: 0) {
            header
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

    private var header: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(ArcaTheme.recording)
                .frame(width: 10, height: 10)
                .opacity(pulseOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.3
                    }
                }
                .onDisappear { pulseOpacity = 1.0 }

            if let startedAt = coordinator.startedAt {
                Text(startedAt, style: .timer)
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .contentTransition(.numericText())
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
                Label(coordinator.phase == .stopping ? "Finishing up…" : "Stop recording",
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
            Label("Rough notes", systemImage: "square.and.pencil")
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
                    locale: TranscriptionPrefs.liveLocale,
                    languageHints: TranscriptionPrefs.languageHints)
            }
        } label: {
            Circle()
                .fill(ArcaTheme.idle)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
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
