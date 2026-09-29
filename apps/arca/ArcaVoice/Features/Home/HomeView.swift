#if os(iOS)
import SwiftUI
import SwiftData
import Photos
import UIKit
import os
import ArcaVoiceKit

/// iPhone home: ARCA itself. The spirit floats mid-screen — tap it and it
/// listens (recording + live transcription), tap again to wrap up. Take a
/// screenshot anywhere while the app is open and ARCA offers to read it.
struct HomeView: View {
    @State private var services = AppServices.shared
    @State private var vitals = VitalsEngine.shared
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarded") private var onboarded = false
    @State private var screenshotOffered = false
    /// Shown only when the calendar says this is a meeting — see `tapFace`.
    @State private var showingParticipantPrep = false
    @State private var readingShot = false
    @State private var shotResult: String?
    @State private var shotFailed = false
    @State private var tapBounce = false
    /// Which section the home is presenting. One piece of state for all of them
    /// so the phone and the Mac reach the same places by the same names.
    @State private var openSection: ArcaSection?
    @State private var openedDaySession: RecordingSession?

    private var phase: RecordingCoordinator.Phase { services.coordinator.phase }

    @Query(filter: #Predicate<TodoTask> { $0.stateRaw == "open" && $0.actionKindRaw != "manual" },
           sort: \TodoTask.createdAt, order: .reverse)
    private var askingTasks: [TodoTask]
    @State private var showingTasks = false

    /// "대신 처리할 수 있는 일 N개" — the one card that leads to 할 일.
    private var delegationCard: some View {
        Button { showingTasks = true } label: {
            HStack(spacing: 12) {
                ArcaFace(mood: .idle, size: 34, halo: false)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("제가 대신 처리할 수 있는 일 \(askingTasks.count)개", "\(askingTasks.count) things I can handle for you"))
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(askingTasks.first?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingTasks) { TaskListView() }
    }

    private var mood: SpiritFace.Mood {
        switch phase {
        case .recording: return .listening
        case .stopping: return .thinking
        case .idle: return readingShot ? .thinking : .idle
        }
    }

    var body: some View {
        ZStack {
            ArcaTheme.spiritNight.ignoresSafeArea()

            // Scrolls now that the home carries the morning card and the section
            // list. The hero still owns the first screenful; the cards peeking
            // below are what tell you there's more down there.
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 10)

                // ARCA sits inside your focus ring: the companion and the state
                // of your body are one object, not a widget bolted next to one.
                ZStack {
                    // An empty grey ring around the face read as a broken
                    // widget to anyone without a Watch — draw it only with data.
                    if vitals.ringScore != nil {
                        FocusRing(score: vitals.ringScore, isLive: vitals.ringIsLive,
                                  lineWidth: 7, trackOpacity: 0.07)
                            .frame(width: 250, height: 250)
                            .allowsHitTesting(false)
                    }
                    SpiritFace(mood: mood, size: 190)
                        .scaleEffect(tapBounce ? 0.88 : 1.0)
                        .onTapGesture { tapFace() }
                }

                statusLine

                Spacer(minLength: 10)

                // The beta home is the core loop only: tap to record, and
                // whatever ARCA is waiting to hear "네" on. Condition, 하루 and
                // 위키 stay reachable from their own screens.
                if !askingTasks.isEmpty {
                    delegationCard
                }

                if let shotResult {
                    resultCard(shotResult)
                }
                if screenshotOffered {
                    screenshotBanner
                }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
            OnboardingView { onboarded = true }
        }
        .sheet(item: $openSection) { section in
            NavigationStack {
                sectionScreen(section)
                    .navigationTitle(section.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("닫기", "Close")) { openSection = nil }
                        }
                    }
                    .navigationDestination(item: $openedDaySession) { session in
                        SessionDetailView(session: session)
                    }
            }
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
        // Looked up ahead of the tap, never during it: the phone's recording
        // gesture has to stay instant.
        .task { await services.participantPrep.refreshDetectedMeeting() }
        .sheet(isPresented: $showingParticipantPrep) {
            ParticipantPrepView(
                prep: services.participantPrep,
                meetingLabel: services.participantPrep.detectedMeeting?.title,
                ownerName: services.ownerName,
                onStart: {
                    let planned = services.participantPrep.participants
                    showingParticipantPrep = false
                    services.startRecording(participants: planned)
                },
                onCancel: { showingParticipantPrep = false })
                .presentationDetents([.medium, .large])
        }
        .alert(L("녹음 오류", "Recording error"), isPresented: Binding(
            get: { services.coordinator.errorMessage != nil },
            set: { if !$0 { services.coordinator.errorMessage = nil } }
        )) {
            Button(L("확인", "OK")) { services.coordinator.errorMessage = nil }
        } message: {
            Text(services.coordinator.errorMessage ?? "")
        }
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
        case .idle:
            // A meeting gets one chance to collect names; everything else keeps
            // the one-tap behaviour the whole screen is built around.
            if services.participantPrep.shouldOfferPrep() {
                services.participantPrep.reset()
                services.participantPrep.markOffered()
                showingParticipantPrep = true
            } else {
                services.startRecording()
            }
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
                Text(L("듣고 있어요 — 누르면 마무리할게요", "Listening — tap me to wrap up"))
                    .font(.subheadline)
                    .foregroundStyle(ArcaFace.ember)
            }
        case .stopping:
            Text(L("마무리하는 중…", "Wrapping up…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .idle:
            VStack(spacing: 4) {
                Text(readingShot
                     ? L("스크린샷을 읽고 있어요…", "Reading your screenshot…")
                     : L("눌러보세요 — 제가 들을게요.", "Tap me — I'll listen."))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                if !readingShot {
                    Text(L("회의, 아이디어, 무엇이든요. 전사하고 기억해 둘게요.",
                           "Meetings, ideas, anything. I transcribe and remember."))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Vitals

    /// The one-line read on the body, and the way into the full 컨디션 screen.
    /// Says "측정을 시작할까요?" rather than showing a zero when nothing is measured.
    /// Routes a section to its screen. The same view types the Mac companion
    /// shows in its sidebar, so a section can't quietly mean two things.
    @ViewBuilder
    private func sectionScreen(_ section: ArcaSection) -> some View {
        switch section {
        case .condition:
            VitalsView()
        case .day:
            DayLogView { session in openedDaySession = session }
        case .wiki:
            UserWikiScreen()
        case .skills:
            SkillsView()
        case .shop:
            ShopView()
        case .home, .chat, .tasks, .memory, .library:
            // Reached only if the card list grows; these have their own tabs.
            VitalsView()
        }
    }

    // MARK: - Screenshot flow

    private var screenshotBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .foregroundStyle(.orange)
            Text(L("좋은 스크린샷이네요. 읽어볼까요?", "Nice shot. Want me to read it?"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Button(L("읽어줘", "Read it")) {
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
                Label(shotFailed
                        ? L("끝까지 못 갔어요", "Couldn't finish that")
                        : L("액션 플랜을 저장했어요", "Action plan saved"),
                      systemImage: shotFailed ? "exclamationmark.triangle" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(shotFailed ? .orange : ArcaFace.ember)
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
        RecordingActivityController.shared.note(
            L("스크린샷을 읽고 있어요…", "Reading your screenshot…"), for: 45)
        Task { @MainActor in
            defer { readingShot = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                showShotResult(L("사진 접근 권한이 필요해요 — 설정에서 허용하고 다시 시도해 주세요.",
                                 "Photos access needed — allow it in Settings and try again."),
                               failed: true)
                return
            }
            guard let key = ArcaCloud.anthropicKey, !key.isEmpty else {
                showShotResult(L("Anthropic 키가 필요해요 — 설정을 확인해 주세요.",
                                 "Anthropic key needed — check Settings."),
                               failed: true)
                return
            }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            options.predicate = NSPredicate(
                format: "(mediaSubtype & %d) != 0",
                PHAssetMediaSubtype.photoScreenshot.rawValue)
            guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
                showShotResult(L("사진에서 스크린샷을 찾지 못했어요.",
                                 "Couldn't find the screenshot in Photos."),
                               failed: true)
                return
            }
            let image = await Self.loadFullQualityImage(for: asset)
            guard let jpeg = image?.jpegData(compressionQuality: 0.7) else {
                showShotResult(L("스크린샷을 불러오지 못했어요 — iCloud에 연결돼 있나요?",
                                 "Couldn't load the screenshot — is iCloud reachable?"),
                               failed: true)
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
                showShotResult(plan.offerLine, failed: false)
            } catch {
                showShotResult(String(UserFacingError.message(for: error).prefix(140)), failed: true)
            }
        }
    }

    private func showShotResult(_ text: String, failed: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(failed ? .warning : .success)
        shotFailed = failed
        withAnimation(.spring(duration: 0.35)) { shotResult = text }
        RecordingActivityController.shared.note(
            failed ? L("스크린샷을 읽지 못했어요", "Couldn't read that screenshot") : text, for: 15)
    }

    /// Fetches the full-quality image, resuming exactly once no matter what
    /// Photos delivers — degraded frame, iCloud error, cancellation, or
    /// nothing at all (a 20s timeout backstops the continuation).
    private static func loadFullQualityImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ image: UIImage?) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: image) }
            }
            let req = PHImageRequestOptions()
            req.deliveryMode = .highQualityFormat
            req.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 1600, height: 1600),
                contentMode: .aspectFit, options: req
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                    || ((info?[PHImageCancelledKey] as? Bool) ?? false)
                if failed {
                    finish(nil)
                } else if !degraded {
                    finish(image)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(20))
                finish(nil)
            }
        }
    }
}
#endif
