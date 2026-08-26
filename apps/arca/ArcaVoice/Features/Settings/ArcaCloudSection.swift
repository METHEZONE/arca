import SwiftUI
import ArcaVoiceKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension Notification.Name {
    /// Web onboarding deep-linked back in (`arca://linked`). The ARCA Cloud
    /// section refetches on this rather than making the user close and reopen
    /// 설정 to see that the link they just made took.
    static let arcaCloudLinked = Notification.Name("arca.cloudLinked")
}

/// "ARCA Cloud" in 설정 — the app's half of the account link.
///
/// The web can't reach into the app to fetch a code, and the app can't create
/// an account (that's a browser flow, with email and OAuth in it). So the join
/// is a copy-paste: this section shows the device token, onboarding consumes
/// it, and `arca://linked` tells the app to look again.
///
/// Nothing here is load-bearing for recording. If the cloud is unreachable, the
/// deploy doesn't serve these routes, or the deployment has no device secret,
/// the whole section settles on 연결 안 됨 and the app carries on exactly as
/// before — so this must never be the reason someone can't record a meeting.
struct ArcaCloudSection: View {
    @State private var code: String?
    @State private var status: ArcaCloudAccount.LinkStatus?
    @State private var loading = true
    @State private var copied = false

    var body: some View {
        Section {
            statusRow

            if let code {
                codeRow(code)
                Button {
                    openExternal(ArcaCloudAccount.onboardingURL)
                } label: {
                    Label("온보딩 열기", systemImage: "safari")
                }
            }

            if let status, status.linked {
                if let sessions = status.sessionCount {
                    LabeledContent("기록한 회의", value: "\(sessions)회")
                }
                if let hours = status.audioHours {
                    LabeledContent("전사한 시간", value: String(format: "%.1f시간", hours))
                }
            }
        } header: {
            Text("ARCA Cloud")
        } footer: {
            Text(footer)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .arcaCloudLinked)) { _ in
            Task { await load() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("확인 중…")
                    .foregroundStyle(.secondary)
            }
        } else if let status, status.linked {
            VStack(alignment: .leading, spacing: 4) {
                Label("연결됨", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let email = status.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let plan = status.plan {
                    Text(planLabel(plan))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.14), in: Capsule())
                }
            }
        } else if status != nil {
            Label("미연결", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        } else {
            Label("연결 안 됨", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func codeRow(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("기기 연결 코드")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    copy(code)
                } label: {
                    Label(copied ? "복사됨 ✓" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var footer: String {
        if let status, status.linked {
            return "이 기기는 ARCA Cloud 계정에 연결되어 있습니다. 사용량은 계정 기준으로 집계됩니다."
        }
        if code == nil {
            return "ARCA Cloud에 연결할 수 없습니다. 오프라인이거나 서버가 아직 준비되지 않았을 수 있어요. 녹음·요약 등 나머지 기능은 그대로 동작합니다."
        }
        return "온보딩 열기 → 로그인 → 기기 연결 단계에서 위 코드를 붙여넣으면 이 기기가 계정에 연결됩니다. 코드는 이 기기에서만 유효한 값이니 다른 사람에게 공유하지 마세요."
    }

    /// Matches the published tiers on the pricing page.
    private func planLabel(_ plan: String) -> String {
        switch plan {
        case "free": return "Companion"
        case "pro": return "Second Self"
        case "team": return "ZONE for Teams"
        default: return plan
        }
    }

    private func load() async {
        loading = true
        code = await ArcaCloudAccount.linkCode()
        status = await ArcaCloudAccount.refreshLinkStatus()
        loading = false
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func openExternal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #else
        _ = url
        #endif
    }
}
