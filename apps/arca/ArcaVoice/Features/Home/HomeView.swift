#if os(iOS)
import SwiftUI
import SwiftData
import Photos
import UIKit
import ArcaVoiceKit

/// iPhone home: ARCA itself. The spirit floats mid-screen — tap it and it
/// listens (recording + live transcription), tap again to wrap up. Take a
/// screenshot anywhere while the app is open and ARCA offers to read it.
struct HomeView: View {
    @State private var services = AppServices.shared
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarded") private var onboarded = false
    @State private var screenshotOffered = false
    @State private var readingShot = false
    @State private var shotResult: String?
    @State private var tapBounce = false

    private var phase: RecordingCoordinator.Phase { services.coordinator.phase }

    private var mood: SpiritFace.Mood {
        switch phase {
        case .recording: return .listening
        case .stopping: return .thinking
        case .idle: return readingShot ? .thinking : .idle
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.05, blue: 0.09).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                SpiritFace(mood: mood, size: 190)
                    .scaleEffect(tapBounce ? 0.88 : 1.0)
                    .onTapGesture { tapFace() }

                statusLine

                Spacer()

                if let shotResult {
                    resultCard(shotResult)
                }
                if screenshotOffered {
                    screenshotBanner
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
            OnboardingView { onboarded = true }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard phase == .idle, !readingShot else { return }
            withAnimation(.spring(duration: 0.35)) { screenshotOffered = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                withAnimation { screenshotOffered = false }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { RecordingActivityController.shared.startCompanion() }
        }
        .onAppear { RecordingActivityController.shared.startCompanion() }
    }

    // MARK: - Face interactions

    private func tapFace() {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        withAnimation(.spring(duration: 0.16)) { tapBounce = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { tapBounce = false }
        }
        switch phase {
        case .idle: services.startRecording()
        case .recording: services.stopRecording()
        case .stopping: break
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .recording:
            VStack(spacing: 6) {
                if let startedAt = services.coordinator.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Listening — tap me to wrap up")
                    .font(.subheadline)
                    .foregroundStyle(ArcaFace.ember)
            }
        case .stopping:
            Text("Wrapping up…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .idle:
            VStack(spacing: 4) {
                Text(readingShot ? "Reading your screenshot…" : "Tap me — I'll listen.")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                if !readingShot {
                    Text("Meetings, ideas, anything. I transcribe and remember.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    // MARK: - Screenshot flow

    private var screenshotBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .foregroundStyle(.orange)
            Text("Nice shot. Want me to read it?")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Button("Read it") {
                withAnimation { screenshotOffered = false }
                readLatestScreenshot()
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcaFace.ember)
            .controlSize(.small)
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func resultCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Action plan saved", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ArcaFace.ember)
                Spacer()
                Button {
                    withAnimation { shotResult = nil }
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Grabs the newest screenshot from Photos and runs the vision pipeline —
    /// same magic as the Mac notch, one tap instead of zero.
    private func readLatestScreenshot() {
        readingShot = true
        Task { @MainActor in
            defer { readingShot = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                shotResult = "Photos access needed — allow it in Settings and try again."
                return
            }
            guard let key = KeychainStore.get(.anthropic), !key.isEmpty else {
                shotResult = "Anthropic key needed — check Settings."
                return
            }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            options.predicate = NSPredicate(
                format: "(mediaSubtype & %d) != 0",
                PHAssetMediaSubtype.photoScreenshot.rawValue)
            guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
                shotResult = "Couldn't find the screenshot in Photos."
                return
            }
            let image: UIImage? = await withCheckedContinuation { continuation in
                let req = PHImageRequestOptions()
                req.deliveryMode = .highQualityFormat
                req.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 1600, height: 1600),
                    contentMode: .aspectFit, options: req
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !degraded { continuation.resume(returning: image) }
                }
            }
            guard let jpeg = image?.jpegData(compressionQuality: 0.7) else {
                shotResult = "Couldn't load the screenshot."
                return
            }
            do {
                let plan = try await ClaudeVisionPlanner(apiKey: key)
                    .plan(imageData: jpeg, mediaType: "image/jpeg")
                let record = RecordingSession(title: "📸 \(plan.title)", source: .screenshot)
                record.state = .ready
                let note = SessionNote()
                note.summaryMarkdown = plan.insightMarkdown
                note.actionItemsJSON = try? JSONEncoder().encode(plan.actionItems)
                record.note = note
                context.insert(record)
                try? context.save()
                withAnimation(.spring(duration: 0.35)) { shotResult = plan.offerLine }
            } catch {
                shotResult = String(UserFacingError.message(for: error).prefix(140))
            }
        }
    }
}
#endif
