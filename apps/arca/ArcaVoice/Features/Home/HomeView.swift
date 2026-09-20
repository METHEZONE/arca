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
    /// Shown only when the calendar says this is a meeting — see `tapFace`.
    @State private var showingParticipantPrep = false
    @State private var readingShot = false
    @State private var shotResult: String?
    @State private var shotFailed = false
    /// Set only when the plan just read had at least one dated action item —
    /// this is what the "create the schedule now?" prompt keys off of.
    @State private var scheduleSession: RecordingSession?
    @State private var creatingSchedule = false
    @State private var scheduleMessage: String?
    @State private var tapBounce = false
    /// Which section the home is presenting. One piece of state for all of them
    /// so the phone and the Mac reach the same places by the same names.
    @State private var openSection: ArcaSection?
    @State private var openedDaySession: RecordingSession?

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
                    FocusRing(score: vitals.ringScore, isLive: vitals.ringIsLive,
                              lineWidth: 7, trackOpacity: 0.07)
                        .frame(width: 250, height: 250)
                        .allowsHitTesting(false)
                    SpiritFace(mood: mood, size: 190)
                        .scaleEffect(tapBounce ? 0.88 : 1.0)
                        .onTapGesture { tapFace() }
                }

                statusLine

                vitalsChip

                Spacer(minLength: 10)

                MorningMomentCard { openSection = .condition }

                RecoveredTimeCard()

                // The same sections the Mac sidebar has, by the same names — so
                // 하루 and 위키 aren't Mac-only features any more.
                ArcaSectionCards(sections: ArcaSection.phoneSecondary) { section in
                    openSection = section
                }

                DevicePresenceBar(compact: true)

                if let shotResult {
                    resultCard(shotResult)
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
            // No tap needed any more — ARCA reads it right away, saves the
            // summary to memory, and (via Handoff) offers itself on the Mac
            // the moment it's ready.
            guard phase == .idle, !readingShot else { return }
            readLatestScreenshot()
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
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
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
        case .home, .tasks, .memory, .library:
            // Reached only if the card list grows; these have their own tabs.
            VitalsView()
        }
    }

    private var vitalsChip: some View {
        Button {
            openSection = .condition
        } label: {
            HStack(spacing: 8) {
                Image(systemName: vitals.ringIsLive ? "target" : "bolt.heart.fill")
                    .font(.caption)
                    .foregroundStyle(FocusRing.tint(for: vitals.ringScore))
                if let score = vitals.ringScore {
                    Text(vitals.ringIsLive
                         ? L("몰입 \(score)", "Focus \(score)")
                         : L("준비도 \(score)", "Readiness \(score)"))
                        .font(.system(.caption, design: .rounded, weight: .bold))
                    Text("·")
                        .foregroundStyle(.white.opacity(0.3))
                    Text(vitals.ringLabel)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(L("컨디션 측정 시작하기", "Start tracking your condition"))
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.arcaPress)
    }

    // MARK: - Screenshot flow

    private func resultCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(shotFailed
                        ? L("끝까지 못 갔어요", "Couldn't finish that")
                        : L("액션 플랜을 저장했어요", "Action plan saved"),
                      systemImage: shotFailed ? "exclamationmark.triangle" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(shotFailed ? .orange : ArcaFace.ember)
                Spacer()
                Button {
                    withAnimation {
                        shotResult = nil
                        scheduleSession = nil
                        scheduleMessage = nil
                    }
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)

            if let scheduleSession {
                scheduleRow(for: scheduleSession)
            }
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// The "바로 일정 생성해줄까?" prompt — only shown when the plan actually
    /// found a dated item worth turning into a calendar event.
    @ViewBuilder
    private func scheduleRow(for session: RecordingSession) -> some View {
        Divider().overlay(.white.opacity(0.1))
        if let scheduleMessage {
            Label(scheduleMessage, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(.blue)
                Text(L("날짜가 있는 항목을 찾았어요. 지금 일정 만들어줄까요?",
                       "Found items with a date. Create the schedule now?"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if creatingSchedule {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("만들기", "Create")) { createScheduleNow(for: session) }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.small)
                }
            }
        }
    }

    /// Turns every dated action item on the saved plan into a real calendar
    /// event — the button's response to "바로 일정 생성해줄까?".
    private func createScheduleNow(for session: RecordingSession) {
        guard !creatingSchedule else { return }
        creatingSchedule = true
        Task { @MainActor in
            defer { creatingSchedule = false }
            guard let data = session.note?.actionItemsJSON,
                  var items = try? JSONDecoder().decode([MeetingNotes.ActionItem].self, from: data) else {
                scheduleMessage = L("일정을 만들지 못했어요", "Couldn't create the schedule")
                return
            }
            var created = 0
            for index in items.indices {
                guard let due = items[index].due, items[index].calendarEventID == nil else { continue }
                do {
                    let eventID = try await CalendarEventCreator.create(
                        title: items[index].text, start: due,
                        description: session.note?.summaryMarkdown ?? "")
                    items[index].calendarEventID = eventID
                    created += 1
                } catch {
                    continue // one bad item shouldn't block the rest
                }
            }
            session.note?.actionItemsJSON = try? JSONEncoder().encode(items)
            session.touch()
            try? context.save()
            RelaySync.shared.scheduleSync()
            UINotificationFeedbackGenerator().notificationOccurred(created > 0 ? .success : .warning)
            scheduleMessage = created > 0
                ? L("일정 \(created)개를 캘린더에 추가했어요", "Added \(created) event\(created == 1 ? "" : "s") to your calendar")
                : L("일정을 만들지 못했어요 — 캘린더 접근을 확인해 주세요",
                    "Couldn't create the schedule — check calendar access")
        }
    }

    /// Grabs the newest screenshot from Photos and runs the vision pipeline —
    /// same magic as the Mac notch, one tap instead of zero.
    private func readLatestScreenshot() {
        readingShot = true
        scheduleSession = nil
        scheduleMessage = nil
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
                // Push it now (not the default debounce) — the whole point of
                // the Handoff icon on the Mac is that this session is already
                // there to open by the time someone clicks it.
                RelaySync.shared.scheduleSync(after: 1)
                ScreenshotHandoff.shared.publish(
                    sessionUID: record.directoryName, title: plan.title, hasSchedule: plan.needsSchedule)
                if plan.needsSchedule { scheduleSession = record }
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
