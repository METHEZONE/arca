#if os(macOS)
import SwiftUI

/// The end-of-ZONE report. Left/top: what ARCA handled while you were focused.
/// Then, one at a time, the items that still need you — presented as
/// interview-style choice cards (a recommendation + a one-line explanation on
/// each), so you clear them fast, RPG-quest style.
struct ZoneReportView: View {
    @Bindable var zone: ZoneEngine
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if zone.attention.isEmpty {
                allClear
            } else if index < zone.attention.count {
                questCard(zone.attention[index])
            } else {
                allClear
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "moon.stars.fill").foregroundStyle(ArcaTheme.idle)
                Text("ZONE Report").font(.title2.weight(.bold))
            }
            if let started = zone.startedAt {
                Text("In focus since \(started, style: .time)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // What ARCA handled — the "I took care of these" side.
    private var handledSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("ARCA handled (\(zone.handled.count))", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
            if zone.handled.isEmpty {
                Text("Nothing needed auto-handling.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(zone.handled) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.summary).font(.callout)
                            Text(item.action).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // One needs-you item as a choice quest.
    private func questCard(_ item: ZoneEngine.AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Needs your response")
                    .font(.headline).foregroundStyle(.orange)
                Spacer()
                Text("\(index + 1) / \(zone.attention.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.title).font(.title3.weight(.semibold)).lineLimit(2)
            if !item.context.isEmpty {
                Text(item.context).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }

            VStack(spacing: 8) {
                ForEach(item.choices) { choice in
                    Button {
                        zone.resolve(item, choice: choice)
                        advance()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: choice.executionPlan != nil ? "sparkles" : "hand.point.up.left")
                                .foregroundStyle(choice.executionPlan != nil ? ArcaTheme.idle : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(choice.label).font(.callout.weight(.semibold))
                                    if choice.isRecommended {
                                        Text("Recommended").font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(ArcaTheme.idle, in: Capsule())
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(choice.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(choice.isRecommended ? ArcaTheme.idle.opacity(0.12) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.arcaPress)
                }
                Button("I'll look later") { advance() }
                    .buttonStyle(.arcaPress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var allClear: some View {
        VStack(spacing: 14) {
            handledSummary
            VStack(spacing: 6) {
                Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(ArcaTheme.idle)
                Text("Everything that needed a response is cleared.").font(.headline)
                Text("Good flow. Feel free to get back to focusing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack {
            if !zone.attention.isEmpty && index < zone.attention.count {
                Button("View handled items") { index = zone.attention.count }
                    .buttonStyle(.arcaPress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { zone.showReport = false; dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func advance() {
        withAnimation(.spring(duration: 0.3)) { index += 1 }
    }
}
#endif
