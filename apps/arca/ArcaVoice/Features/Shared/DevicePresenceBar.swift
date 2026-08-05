import SwiftUI
import ArcaVoiceKit

/// "이 맥 · 아이폰 3분 전" — the other device, made visible.
///
/// The Mac and the iPhone have shared a task list, a transcript library, and now
/// a body for a while, but neither app ever said the other existed. So the
/// honest data sharing read as two apps that happened to look alike. This is the
/// smallest surface that fixes that: on both platforms, in the same words.
///
/// It also has to be truthful when sync is broken — a presence bar that shows a
/// stale "아이폰 · 2분 전" while the relay has been failing for a day is worse
/// than showing nothing.
struct DevicePresenceBar: View {
    var compact = false

    @State private var presence = DevicePresence.shared
    @State private var relay = RelaySync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(presence.devices) { device in
                    chip(for: device)
                }
                if presence.peers.isEmpty {
                    Text(Self.soloHint)
                        .font(.system(size: compact ? 10 : 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // What the other device is doing right now — the half of "one app"
            // that presence alone doesn't deliver.
            if let peer = presence.activePeer, let activity = peer.activityLine() {
                HStack(spacing: 5) {
                    Image(systemName: peer.symbol)
                        .font(.system(size: 9, weight: .semibold))
                    Text(L("\(peer.displayName)에서 \(activity)",
                           "\(activity) on your \(peer.displayName)"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(ArcaTheme.pixel)
            }

            if let error = relay.lastError {
                Label(L("기기 동기화가 실패하고 있어요 — \(error)",
                        "Device sync is failing — \(error)"),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let at = relay.lastSyncAt, !compact {
                // `\(date, style:)` is a `LocalizedStringKey` interpolation, so it
                // can't go through `L(_:_:)` (which deals in plain `String`) —
                // branch on the language and keep the self-updating Text.
                (ArcaLanguage.isKorean
                    ? Text("\(at, style: .relative) 전에 맞춰봤어요")
                    : Text("Synced \(at, style: .relative) ago"))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
    }

    private func chip(for device: DeviceHeartbeat) -> some View {
        let awake = device.isSelf || device.isRecent()
        return HStack(spacing: 5) {
            Circle()
                .fill(awake ? ConnectorPalette.green : .white.opacity(0.22))
                .frame(width: 5, height: 5)
            Image(systemName: device.symbol)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(label(for: device))
                .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(awake ? 0.78 : 0.38))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: Capsule())
        .help(tooltip(for: device))
    }

    private func label(for device: DeviceHeartbeat) -> String {
        guard !device.isSelf else {
            return L("이 \(device.displayName)", "This \(device.displayName)")
        }
        return device.displayName
    }

    private func tooltip(for device: DeviceHeartbeat) -> String {
        if device.isSelf {
            return L("지금 쓰고 있는 기기 · ARCA \(device.appVersion)",
                     "The device you're using · ARCA \(device.appVersion)")
        }
        let ago = Self.relativeLabel(device.lastSeenAt)
        return L("\(device.displayName) · \(ago) 확인 · ARCA \(device.appVersion)",
                 "\(device.displayName) · seen \(ago) · ARCA \(device.appVersion)")
    }

    /// "3분 전" / "3 minutes ago", in whichever language ARCA is speaking.
    static func relativeLabel(_ date: Date, relativeTo now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: ArcaLanguage.isKorean ? "ko_KR" : "en_US")
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static var soloHint: String {
        #if os(macOS)
        return L("아이폰 ARCA를 열면 여기 같이 표시돼요",
                 "Open ARCA on your iPhone and it shows up here")
        #else
        return L("맥 ARCA를 열면 여기 같이 표시돼요",
                 "Open ARCA on your Mac and it shows up here")
        #endif
    }
}

/// The row of section entry cards — the same names, icons, and blurbs on both
/// platforms, so 하루/위키/컨디션 aren't things that only exist on one device.
struct ArcaSectionCards: View {
    let sections: [ArcaSection]
    let onOpen: (ArcaSection) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(sections) { section in
                Button {
                    onOpen(section)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ArcaTheme.pixel)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.system(.callout, design: .rounded, weight: .bold))
                            Text(section.recordedOn.note ?? section.blurb)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: ArcaRadius.md))
                }
                .buttonStyle(.arcaPress)
            }
        }
    }
}
