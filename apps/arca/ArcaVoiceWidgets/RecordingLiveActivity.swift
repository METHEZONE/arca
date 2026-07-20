import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents
import ArcaVoiceKit

/// ARCA's presence in the Dynamic Island. Companion mode: the spirit rests up
/// top, one tap from recording. Recording mode: face + timer + live pulse.
/// This is the iPhone analog of the Mac notch agent.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 12) {
                SpiritGlyph(happy: context.state.isLively)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.state.isRecording ? context.attributes.title : "ARCA")
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.isRecording
                         ? (context.state.isPaused ? "Paused" : "Listening")
                         : (context.state.detail ?? "With you — tap to record"))
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(context.state.isRecording ? Color.green : Color(red: 1.0, green: 0.478, blue: 0.102))
                }
                Spacer()
                if context.state.isRecording {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(.title3, design: .monospaced))
                        .frame(width: 66)
                } else {
                    Button(intent: ArcaToggleRecordingIntent()) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color(red: 1.0, green: 0.478, blue: 0.102).opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SpiritGlyph(happy: context.state.isLively)
                        .frame(width: 40, height: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isRecording {
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 64)
                    } else {
                        Button(intent: ArcaToggleRecordingIntent()) {
                            Label("Record", systemImage: "mic.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color(red: 1.0, green: 0.478, blue: 0.102).opacity(0.45), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        if context.state.isRecording {
                            Image(systemName: "waveform")
                                .foregroundStyle(.green)
                            Text(context.state.isPaused ? "Paused — tap to continue" : "ARCA is listening")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Button(intent: ArcaToggleRecordingIntent()) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(.red.opacity(0.8), in: Circle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Image(systemName: context.state.detail == nil ? "sparkles" : "brain.head.profile")
                                .foregroundStyle(Color(red: 1.0, green: 0.478, blue: 0.102))
                                .symbolEffect(.pulse, isActive: context.state.detail != nil)
                            Text(context.state.detail ?? "ARCA is with you")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Link(destination: URL(string: "arca://talk")!) {
                                Label("Talk", systemImage: "waveform.and.mic")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.white.opacity(0.16), in: Capsule())
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                SpiritGlyph(happy: context.state.isLively)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                if context.state.isRecording {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(width: 44)
                } else {
                    Image(systemName: context.state.detail == nil ? "sparkles" : "brain.head.profile")
                        .font(.system(size: 11))
                        .symbolEffect(.pulse, isActive: context.state.detail != nil)
                        .foregroundStyle(Color(red: 1.0, green: 0.478, blue: 0.102))
                }
            } minimal: {
                SpiritGlyph(happy: context.state.isLively)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(context.state.isRecording ? .green : Color(red: 1.0, green: 0.478, blue: 0.102))
        }
    }
}

/// ARCA, island-sized — the round spirit in whatever skin the user picked
/// (palette shared through the App Group via SkinPalette).
private struct SpiritGlyph: View {
    let happy: Bool

    var body: some View {
        let p = SkinPalette.current
        let hi = Color(red: p.hi.r, green: p.hi.g, blue: p.hi.b)
        let mid = Color(red: p.mid.r, green: p.mid.g, blue: p.mid.b)
        let lo = Color(red: p.lo.r, green: p.lo.g, blue: p.lo.b)
        let cream = LinearGradient(
            colors: [Color(red: 1.0, green: 0.965, blue: 0.925),
                     Color(red: 1.0, green: 0.890, blue: 0.788)],
            startPoint: .top, endPoint: .bottom)

        ZStack {
            Circle()
                .fill(RadialGradient(
                    stops: [.init(color: hi, location: 0),
                            .init(color: mid, location: 0.55),
                            .init(color: lo, location: 1)],
                    center: .init(x: 0.36, y: 0.30),
                    startRadius: 0, endRadius: 13))
                .shadow(color: mid.opacity(0.7), radius: 2.5)
            Ellipse()
                .fill(.white.opacity(0.28))
                .frame(width: 8, height: 5)
                .offset(x: -3.5, y: -5)
            HStack(spacing: 2.6) {
                ForEach(0..<2, id: \.self) { _ in
                    if happy {
                        HappyArc()
                            .stroke(cream, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                            .frame(width: 5.5, height: 3)
                    } else {
                        MiniDome()
                            .fill(cream)
                            .frame(width: 4.6, height: 4.4)
                    }
                }
            }
            .offset(y: -0.5)
        }
    }
}

private struct MiniDome: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct HappyArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.5))
        return path
    }
}
