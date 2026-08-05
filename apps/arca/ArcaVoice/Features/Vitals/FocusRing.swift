import SwiftUI
import ArcaVoiceKit

/// The focus ring — ARCA's face sits inside it on the iPhone home, and it shows
/// up small in the Mac's notch dashboard.
///
/// A missing score draws a dashed outline, never a ring trimmed to zero. A score
/// of 0 and "not measured yet" look identical when you fill a ring by fraction,
/// and telling someone their focus is at rock bottom when the truth is that
/// nobody measured is the exact failure that makes people distrust a health app.
struct FocusRing: View {
    let score: Int?
    /// True when the number came from a measurement taken minutes ago rather
    /// than from today's readiness — the ring breathes when it's live.
    var isLive = false
    var lineWidth: CGFloat = 10
    var trackOpacity: Double = 0.10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var tint: Color { Self.tint(for: score) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(trackOpacity), lineWidth: lineWidth)

            if let score {
                Circle()
                    // A floor of 2% so a genuine single-digit score still reads
                    // as a mark on the ring rather than nothing at all.
                    .trim(from: 0, to: max(0.02, Double(score) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(isLive && breathing ? 0.75 : 0.35),
                            radius: isLive && breathing ? 14 : 6)
                    .animation(.spring(duration: 0.6), value: score)
            } else {
                Circle()
                    .stroke(.white.opacity(0.20),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [3, 7]))
            }
        }
        .onAppear { syncBreathing() }
        .onChange(of: isLive) { _, _ in syncBreathing() }
        .onChange(of: reduceMotion) { _, _ in syncBreathing() }
    }

    /// Starts and — importantly — stops the live breath.
    ///
    /// This used to be `.animation(.repeatForever, value: breathing)`, which
    /// applies that same forever-curve to *every* change of the value, including
    /// the one meant to switch the breathing off. The ring therefore kept
    /// animating its shadow radius indefinitely after going stale, on a surface
    /// that can sit in the Mac's notch panel all day. Driving it imperatively
    /// means the stop is a plain easeOut, which actually ends the loop.
    private func syncBreathing() {
        guard isLive, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.3)) { breathing = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }

    /// Higher is better for readiness and focus depth, so the ramp runs from
    /// "rest now" red up through amber to the companion's own cyan.
    static func tint(for score: Int?) -> Color {
        guard let score else { return .white.opacity(0.25) }
        switch score {
        case 80...: return ArcaTheme.pixel
        case 65..<80: return Color(red: 0.42, green: 0.88, blue: 0.62)
        case 50..<65: return Color(red: 0.98, green: 0.82, blue: 0.36)
        case 35..<50: return Color(red: 0.98, green: 0.60, blue: 0.30)
        default: return ArcaTheme.recording
        }
    }

    /// Stress runs the other way — a high number is the bad one.
    static func stressTint(for score: Int?) -> Color {
        guard let score else { return .white.opacity(0.25) }
        return tint(for: 100 - score)
    }
}

/// A number with its label, sized for a row of three.
struct VitalsStatTile: View {
    let title: String
    let score: Int?
    let caption: String
    let tint: Color
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .labelStyle(.titleAndIcon)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(score.map(String.init) ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(score == nil ? .white.opacity(0.35) : tint)
                    .contentTransition(.numericText())
                if score != nil {
                    Text("/100")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            Text(caption)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ArcaSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: ArcaRadius.md))
        .overlay(RoundedRectangle(cornerRadius: ArcaRadius.md)
            .strokeBorder(.white.opacity(0.06)))
    }
}

/// The 24-hour focus profile. One bar per hour, height and brightness by how
/// strongly the user focuses then, relative to their own best hour.
///
/// Bars are drawn only for hours with real observation behind them; an hour with
/// no evidence is left as an empty track rather than a zero-height bar, so
/// "never worked at 4am" doesn't look like "worked terribly at 4am".
struct FocusWindowChart: View {
    let windows: [FocusWindow]
    var highlightHour: Int?

    private var byHour: [Int: FocusWindow] {
        Dictionary(uniqueKeysWithValues: windows.map { ($0.hour, $0) })
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    bar(for: hour)
                }
            }
            .frame(height: 74)

            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(hour == 0 ? L("0시", "0:00") : L("\(hour)시", "\(hour):00"))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func bar(for hour: Int) -> some View {
        let window = byHour[hour]
        let isHighlighted = highlightHour == hour
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(window == nil
                          ? AnyShapeStyle(.white.opacity(0.05))
                          : AnyShapeStyle(FocusRing.tint(for: Int((window?.score ?? 0) * 100))
                              .opacity(isHighlighted ? 1 : 0.72)))
                    .frame(height: window.map { max(3, proxy.size.height * $0.score) } ?? 3)
            }
            .overlay(alignment: .top) {
                if isHighlighted {
                    Circle()
                        .fill(ArcaTheme.pixel)
                        .frame(width: 4, height: 4)
                        .offset(y: -6)
                }
            }
        }
        .accessibilityLabel(Text(window.map {
            L("\($0.label) 몰입 강도 \(Int($0.score * 100))퍼센트",
              "\($0.label), focus intensity \(Int($0.score * 100)) percent")
        } ?? L("\(hour)시 기록 없음", "\(hour):00, nothing recorded")))
    }
}
