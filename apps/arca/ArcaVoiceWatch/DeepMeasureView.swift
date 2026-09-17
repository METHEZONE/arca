import SwiftUI

/// The wrist face of the focus measurement: one ring and one button row.
/// Idle, the ring shows the read the phone computed (or "대기 중" when there
/// is none); measuring, it fills with the minutes and shows the live heart rate.
struct DeepMeasureView: View {
    @State private var status = WatchVitalsStatus.shared
    @State private var seconds = 180

    private static let teal = Color(red: 0.32, green: 0.91, blue: 0.90)

    var body: some View {
        VStack(spacing: 10) {
            ring
                .frame(width: 96, height: 96)

            if let caption {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if status.isMeasuring {
                Button(L("그만하기", "Stop")) { WatchDeepMeasure.shared.stop() }
                    .buttonStyle(.bordered)
                    .tint(.orange)
            } else {
                HStack(spacing: 6) {
                    // Tap to cycle 1 → 3 → 5 minutes; a wheel picker didn't fit a 40mm page.
                    Button("\(seconds / 60)\(L("분", "m"))") {
                        seconds = seconds == 60 ? 180 : (seconds == 180 ? 300 : 60)
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()

                    Button {
                        WatchDeepMeasure.shared.start(seconds: seconds)
                    } label: {
                        Label(L("몰입 측정", "Measure"), systemImage: "target")
                            .font(.system(.footnote, design: .rounded, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Self.teal)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One line under the ring: while measuring "가만히 있어 주세요", otherwise
    /// the phone's read label, then the next focus window, then an error.
    private var caption: String? {
        if status.isMeasuring { return L("가만히 있어 주세요", "Hold still") }
        if let error = status.errorMessage { return error }
        if !status.ringLabel.isEmpty { return status.ringLabel }
        if let next = status.nextWindow { return L("골든타임 \(next)", "Focus window \(next)") }
        return nil
    }

    /// Same ramp as the phone. Restated because the watch target intentionally
    /// links no shared UI code.
    private static func tint(for score: Int) -> Color {
        switch score {
        case 80...: return teal
        case 65..<80: return Color(red: 0.42, green: 0.88, blue: 0.62)
        case 50..<65: return Color(red: 0.98, green: 0.82, blue: 0.36)
        case 35..<50: return Color(red: 0.98, green: 0.60, blue: 0.30)
        default: return Color(red: 0.95, green: 0.26, blue: 0.21)
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: status.isMeasuring ? max(0.01, status.progress) : 0)
                .stroke(Self.teal, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: status.progress)

            VStack(spacing: 1) {
                if status.isMeasuring {
                    if let hr = status.currentHR {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                            Text("\(Int(hr))")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .contentTransition(.numericText())
                        }
                        Text(timeLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("측정 준비…", "Getting ready…"))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else if let score = status.ringScore {
                    Text("\(score)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.tint(for: score))
                    Text(status.ringIsLive ? L("몰입", "Focus") : L("준비도", "Readiness"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "target")
                        .font(.system(size: 24))
                        .foregroundStyle(Self.teal.opacity(0.8))
                    Text(L("대기 중", "Idle"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var timeLabel: String {
        let remaining = status.secondsRemaining
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

#Preview {
    DeepMeasureView()
}
