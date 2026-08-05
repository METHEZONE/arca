import SwiftUI

/// The wrist face of the focus measurement: a ring that fills as the minutes
/// run, the live heart rate in the middle, and one button.
///
/// It says out loud that nothing is being measured when idle, because the honest
/// answer to "is my watch tracking me right now?" should be visible rather than
/// buried in a settings screen.
struct DeepMeasureView: View {
    @State private var status = WatchVitalsStatus.shared
    @State private var seconds = 180

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                bodyRead

                ring
                    .frame(width: 108, height: 108)
                    .padding(.top, 4)

                if status.isMeasuring {
                    Text(L("가만히 있어 주세요", "Hold still"))
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button(L("그만하기", "Stop")) { WatchDeepMeasure.shared.stop() }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                } else {
                    Picker(L("측정 시간", "Measure for"), selection: $seconds) {
                        Text(L("1분", "1 min")).tag(60)
                        Text(L("3분", "3 min")).tag(180)
                        Text(L("5분", "5 min")).tag(300)
                    }
                    .labelsHidden()
                    .frame(height: 52)

                    Button {
                        WatchDeepMeasure.shared.start(seconds: seconds)
                    } label: {
                        Label(L("몰입 측정", "Measure focus"), systemImage: "target")
                            .font(.system(.footnote, design: .rounded, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.32, green: 0.91, blue: 0.90))

                    Text(L("평소에는 아무것도 재지 않아요. 누른 이 시간만 심박을 봅니다.",
                           "Nothing is measured the rest of the time. Only the minutes you ask for."))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let label = status.lastDepthLabel {
                    Label(label, systemImage: "checkmark.circle")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                }
                if let error = status.errorMessage {
                    Text(error)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }

    /// The read the phone computed, shown on the wrist. Hidden while a
    /// measurement is running so the live ring owns the screen.
    @ViewBuilder private var bodyRead: some View {
        if !status.isMeasuring, let score = status.ringScore {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text("\(score)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.tint(for: score))
                    Text(status.ringIsLive ? L("몰입", "Focus") : L("준비도", "Readiness"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if !status.ringLabel.isEmpty {
                    Text(status.ringLabel)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let next = status.nextWindow {
                    Text(L("골든타임 \(next)", "Focus window \(next)"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.32, green: 0.91, blue: 0.90))
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Same ramp as the phone. Restated because the watch target intentionally
    /// links no shared UI code.
    private static func tint(for score: Int) -> Color {
        switch score {
        case 80...: return Color(red: 0.32, green: 0.91, blue: 0.90)
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
                .stroke(Color(red: 0.32, green: 0.91, blue: 0.90),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: status.progress)

            VStack(spacing: 1) {
                if let hr = status.currentHR {
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text("\(Int(hr))")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                    }
                    Text("bpm")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                } else if status.isMeasuring {
                    Text(L("측정 준비…", "Getting ready…"))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "target")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(red: 0.32, green: 0.91, blue: 0.90).opacity(0.8))
                    Text(L("대기 중", "Idle"))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if status.isMeasuring {
                    Text(timeLabel)
                        .font(.system(size: 10, design: .monospaced))
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
