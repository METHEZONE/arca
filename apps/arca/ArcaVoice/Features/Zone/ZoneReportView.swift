#if os(macOS)
import SwiftUI
import ArcaVoiceKit

/// The end-of-ZONE report. Left/top: what ARCA handled while you were focused.
/// Then, one at a time, the items that still need you — presented as
/// interview-style choice cards (a recommendation + a one-line explanation on
/// each), so you clear them fast, RPG-quest style.
struct ZoneReportView: View {
    @Bindable var zone: ZoneEngine
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var vitals = VitalsEngine.shared

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
                Text(L("ZONE 리포트", "ZONE Report")).font(.title2.weight(.bold))
            }
            if let started = zone.startedAt {
                (ArcaLanguage.isKorean
                    ? Text("\(started, style: .time)부터 몰입 중")
                    : Text("In focus since \(started, style: .time)"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            zoneMetric
            bodyLine
        }
    }

    /// ZONE time recovered, and how many interruptions ARCA absorbed so it could
    /// be recovered. This is the product's core metric and the thing the Pro tier
    /// already sells; it belongs above any physiological number, because the
    /// promise is "you got 52 minutes back", not "your HRV was 44ms".
    @ViewBuilder private var zoneMetric: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.caption).foregroundStyle(ArcaTheme.idle)
            Text("ZONE \(VitalsFormat.hoursMinutes(max(1, zone.lastSessionMinutes)))")
                .font(.subheadline.weight(.semibold))
            Text(L("· ARCA가 흡수한 방해 \(zone.handled.count)건",
                   zone.handled.count == 1
                       ? "· ARCA absorbed 1 interruption"
                       : "· ARCA absorbed \(zone.handled.count) interruptions"))
                .font(.caption).foregroundStyle(.secondary)
            if !zone.attention.isEmpty {
                Text(L("· 당신 판단이 필요한 것 \(zone.attention.count)건",
                       zone.attention.count == 1
                           ? "· 1 item needs your call"
                           : "· \(zone.attention.count) items need your call"))
                    .font(.caption).foregroundStyle(.orange.opacity(0.9))
            }
        }
    }

    /// What the user's body was doing while they focused. The session itself is
    /// now evidence for the focus profile, so closing the loop here — "you were
    /// at 78, and this hour is one of your strong ones" — is what turns the
    /// report from a log into something that changes tomorrow's schedule.
    @ViewBuilder private var bodyLine: some View {
        if let score = vitals.ringScore {
            HStack(spacing: 6) {
                FocusRing(score: score, isLive: false, lineWidth: 2.5, trackOpacity: 0.15)
                    .frame(width: 13, height: 13)
                Text(L("몰입 준비도 \(score) · \(vitals.ringLabel)",
                       "Readiness \(score) · \(vitals.ringLabel)"))
                    .font(.caption).foregroundStyle(.secondary)
                if let next = vitals.nextFocusWindow() {
                    Text(L("· 다음 골든타임 \(next.label)", "· Next golden hour \(next.label)"))
                        .font(.caption).foregroundStyle(.secondary.opacity(0.7))
                }
            }
        }
    }

    // What ARCA handled — the "I took care of these" side.
    private var handledSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("ARCA가 처리한 것 (\(zone.handled.count))", "ARCA handled (\(zone.handled.count))"),
                  systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
            if zone.handled.isEmpty {
                Text(L("자동으로 처리할 건 없었어요.", "Nothing needed auto-handling."))
                    .font(.callout).foregroundStyle(.secondary)
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
                Text(L("당신 답이 필요해요", "Needs your response"))
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
                                        Text(L("추천", "Recommended")).font(.caption2.weight(.bold))
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
                Button(L("나중에 볼게요", "I'll look later")) { advance() }
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
                Text(L("답이 필요한 건 다 정리됐어요.", "Everything that needed a response is cleared."))
                    .font(.headline)
                Text(L("흐름 좋아요. 이어서 몰입하세요.", "Good flow. Feel free to get back to focusing."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack {
            if !zone.attention.isEmpty && index < zone.attention.count {
                Button(L("처리된 것 보기", "View handled items")) { index = zone.attention.count }
                    .buttonStyle(.arcaPress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("닫기", "Close")) { zone.showReport = false; dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func advance() {
        withAnimation(.spring(duration: 0.3)) { index += 1 }
    }
}
#endif
