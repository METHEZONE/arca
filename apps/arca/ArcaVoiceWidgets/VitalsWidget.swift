import SwiftUI
import WidgetKit
import ArcaVoiceKit

/// ARCA on the home and lock screen: how ready you are, and when your next good
/// hour is — without opening anything.
///
/// It reads a small snapshot the app writes into the shared App Group, not the
/// day files themselves. The widget process has no business holding sleep
/// architecture or a meal log, and it only needs a handful of numbers.
struct VitalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ArcaVitalsWidget", provider: VitalsTimelineProvider()) { entry in
            VitalsWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.03, green: 0.05, blue: 0.09)
                }
        }
        .configurationDisplayName("ARCA")
        .description(widgetDescription)
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular,
        ])
    }

    /// The widget gallery is rendered by the system outside the app, so the app's
    /// language helper isn't loaded — resolve from the locale directly.
    private var widgetDescription: String {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
            ? "몰입 준비도와 다음 골든타임을 한눈에."
            : "Your readiness for deep work, and the next good hour for it."
    }
}

struct VitalsEntry: TimelineEntry {
    let date: Date
    let snapshot: VitalsSnapshot?
}

struct VitalsTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> VitalsEntry {
        VitalsEntry(date: .now, snapshot: VitalsSnapshot(
            ringScore: 74, isLive: false, label: WidgetCopy.readyLabel,
            nextWindowLabel: "10:00–11:00", sleepMinutes: 430, stress: 28,
            weeklyZoneMinutes: 252, weeklyAbsorbed: 31))
    }

    func getSnapshot(in context: Context, completion: @escaping (VitalsEntry) -> Void) {
        completion(VitalsEntry(date: .now, snapshot: VitalsSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VitalsEntry>) -> Void) {
        let entry = VitalsEntry(date: .now, snapshot: VitalsSnapshotStore.read())
        // The app refreshes vitals every ten minutes and reloads the timeline
        // when the numbers actually change, so this is only a floor for the case
        // where the app never runs.
        let next = Date.now.addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

/// Copy resolved from the locale, since the widget extension runs without the
/// app's language setting loaded.
enum WidgetCopy {
    static var isKorean: Bool {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
    }

    static func pick(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

    static var readyLabel: String { pick("몰입 가능한 상태", "Ready to focus") }
    static var noData: String { pick("아직 측정 전", "Not measured yet") }
    static var connectHint: String {
        pick("ARCA를 열어 건강을 연결하세요", "Open ARCA to connect Health")
    }
    static var nextWindow: String { pick("다음 골든타임", "Next good hour") }
    static var thisWeek: String { pick("이번 주 몰입", "Focus this week") }
    static var absorbed: String { pick("ARCA가 막은 방해", "Interruptions absorbed") }
    static var focusDepth: String { pick("몰입 깊이", "Focus depth") }
    static var readiness: String { pick("몰입 준비도", "Readiness") }

    static func hoursMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return isKorean ? "\(mins)분" : "\(mins)m" }
        if mins == 0 { return isKorean ? "\(hours)시간" : "\(hours)h" }
        return isKorean ? "\(hours)시간 \(mins)분" : "\(hours)h \(mins)m"
    }
}

struct VitalsWidgetView: View {
    let entry: VitalsEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: VitalsSnapshot? {
        guard let snapshot = entry.snapshot, snapshot.hasAnything else { return nil }
        return snapshot
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                WidgetRing(score: snapshot?.ringScore, isLive: snapshot?.isLive ?? false)
                    .frame(width: 42, height: 42)
                    .overlay {
                        Text(snapshot?.ringScore.map(String.init) ?? "—")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                Spacer(minLength: 0)
            }

            Text(snapshot.map { $0.isLive ? WidgetCopy.focusDepth : WidgetCopy.readiness }
                 ?? WidgetCopy.noData)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))

            Text(snapshot?.label ?? WidgetCopy.connectHint)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            if let next = snapshot?.nextWindowLabel {
                Label(next, systemImage: "clock.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.tint(for: snapshot?.ringScore))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            ZStack {
                WidgetRing(score: snapshot?.ringScore, isLive: snapshot?.isLive ?? false)
                    .frame(width: 72, height: 72)
                VStack(spacing: -2) {
                    Text(snapshot?.ringScore.map(String.init) ?? "—")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(snapshot.map { $0.isLive ? WidgetCopy.focusDepth : WidgetCopy.readiness }
                         ?? "")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot?.label ?? WidgetCopy.connectHint)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let next = snapshot?.nextWindowLabel {
                    metric(WidgetCopy.nextWindow, next,
                           tint: WidgetPalette.tint(for: snapshot?.ringScore))
                }
                if let minutes = snapshot?.weeklyZoneMinutes, minutes > 0 {
                    metric(WidgetCopy.thisWeek, WidgetCopy.hoursMinutes(minutes),
                           tint: .white.opacity(0.75))
                }
                if let absorbed = snapshot?.weeklyAbsorbed, absorbed > 0 {
                    metric(WidgetCopy.absorbed,
                           WidgetCopy.isKorean ? "\(absorbed)건" : "\(absorbed)",
                           tint: .white.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Lock screen / watch-style accessories

    private var circular: some View {
        // Accessory families are rendered in a tinted, low-colour environment, so
        // the ring carries the value as a gauge rather than by hue.
        Gauge(value: Double(snapshot?.ringScore ?? 0), in: 0...100) {
            Image(systemName: "bolt.heart")
        } currentValueLabel: {
            Text(snapshot?.ringScore.map(String.init) ?? "—")
                .font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 10))
                Text(snapshot.map { $0.isLive ? WidgetCopy.focusDepth : WidgetCopy.readiness }
                     ?? "ARCA")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            Text(snapshot?.ringScore.map { "\($0) · \(snapshot?.label ?? "")" }
                 ?? WidgetCopy.noData)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
            if let next = snapshot?.nextWindowLabel {
                Text("\(WidgetCopy.nextWindow) \(next)")
                    .font(.system(size: 11, design: .rounded))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum WidgetPalette {
    /// Same ramp as the app's ring, restated here because the widget target
    /// doesn't link the app's design system.
    static func tint(for score: Int?) -> Color {
        guard let score else { return .white.opacity(0.3) }
        switch score {
        case 80...: return Color(red: 0.32, green: 0.91, blue: 0.90)
        case 65..<80: return Color(red: 0.42, green: 0.88, blue: 0.62)
        case 50..<65: return Color(red: 0.98, green: 0.82, blue: 0.36)
        case 35..<50: return Color(red: 0.98, green: 0.60, blue: 0.30)
        default: return Color(red: 0.95, green: 0.26, blue: 0.21)
        }
    }
}

/// A missing score draws a dashed ring, never one trimmed to zero — same rule as
/// in the app, because "not measured" and "you're at rock bottom" must not look
/// the same on someone's home screen.
struct WidgetRing: View {
    let score: Int?
    let isLive: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 6)
            if let score {
                Circle()
                    .trim(from: 0, to: max(0.02, Double(score) / 100))
                    .stroke(WidgetPalette.tint(for: score),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .stroke(.white.opacity(0.22),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [2, 5]))
            }
        }
    }
}
