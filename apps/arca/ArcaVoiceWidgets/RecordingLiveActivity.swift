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
                SpiritGlyph(happy: context.state.isLively, pose: context.state.restingPose)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.state.isRecording ? context.attributes.title : "ARCA")
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.isRecording
                         ? (context.state.isPaused ? WidgetCopy.pick("일시정지", "Paused") : WidgetCopy.pick("듣고 있어요", "Listening"))
                         : (context.state.detail ?? Pose.caption(context.state.pose) ?? WidgetCopy.pick("곁에 있어요 — 탭하면 녹음", "With you — tap to record")))
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
                    SpiritGlyph(happy: context.state.isLively, pose: context.state.restingPose)
                        .frame(width: 44, height: 44)
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
                            Text(context.state.isPaused ? WidgetCopy.pick("일시정지 — 탭하면 계속", "Paused — tap to continue") : WidgetCopy.pick("ARCA가 듣고 있어요", "ARCA is listening"))
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
                            Image(systemName: context.state.detail == nil ? Pose.symbol(context.state.pose) : "brain.head.profile")
                                .foregroundStyle(Color(red: 1.0, green: 0.478, blue: 0.102))
                                .symbolEffect(.pulse, isActive: context.state.detail != nil)
                            Text(context.state.detail ?? Pose.caption(context.state.pose) ?? WidgetCopy.pick("ARCA가 곁에 있어요", "ARCA is with you"))
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
                SpiritGlyph(happy: context.state.isLively, pose: context.state.restingPose)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                if context.state.isRecording {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(width: 44)
                } else {
                    Image(systemName: context.state.detail == nil ? Pose.symbol(context.state.pose) : "brain.head.profile")
                        .font(.system(size: 11, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, isActive: context.state.detail != nil)
                        .foregroundStyle(Color(red: 1.0, green: 0.478, blue: 0.102))
                }
            } minimal: {
                SpiritGlyph(happy: context.state.isLively, pose: context.state.restingPose)
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
    var pose: String? = nil

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
                    if pose == "sleep" {
                        // Closed crescents: dozing.
                        HappyArc()
                            .stroke(cream, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .frame(width: 5.5, height: 2.4)
                            .scaleEffect(y: -1)
                    } else if pose == "code" || pose == "tv" {
                        // Concentrating squint.
                        MiniDome()
                            .fill(cream)
                            .frame(width: 4.8, height: 2.4)
                    } else if happy || pose == "meal" || pose == "music" {
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
        .rotationEffect(.degrees(pose == "music" ? 9 : pose == "sleep" ? -10 : pose == "stretch" ? -5 : 0))
        .overlay(alignment: .bottomTrailing) {
            // The prop in its hands — a bowl, a laptop, headphones, a "z".
            if let pose {
                Image(systemName: Pose.symbol(pose))
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white)
                    .padding(1.6)
                    .background(Circle().fill(Color(red: 1.0, green: 0.478, blue: 0.102)))
                    .offset(x: 1, y: 2)
                    .transition(.scale.combined(with: .opacity))
                    .id(pose)
            }
        }
    }
}

/// The island's resting activities — the iPhone side of the Mac notch life loop.
enum Pose {
    static func caption(_ pose: String?) -> String? {
        switch pose {
        case "meal": return WidgetCopy.pick("밥 먹는 중", "Having a meal")
        case "code": return WidgetCopy.pick("코딩하는 중", "Coding away")
        case "tv": return WidgetCopy.pick("TV 보는 중", "Watching TV")
        case "music": return WidgetCopy.pick("음악 듣는 중", "Listening to music")
        case "stretch": return WidgetCopy.pick("스트레칭 중", "Stretching")
        case "sleep": return WidgetCopy.pick("꾸벅꾸벅 조는 중", "Dozing off")
        default: return nil
        }
    }

    static func symbol(_ pose: String?) -> String {
        switch pose {
        case "meal": return "fork.knife"
        case "code": return "laptopcomputer"
        case "tv": return "tv.fill"
        case "music": return "headphones"
        case "stretch": return "figure.cooldown"
        case "sleep": return "zzz"
        default: return "sparkles"
        }
    }
}

private extension RecordingActivityAttributes.ContentState {
    /// A pose only while resting — recording and working faces stay as they are.
    var restingPose: String? { isRecording || detail != nil ? nil : pose }
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
