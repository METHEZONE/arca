#if os(macOS)
import SwiftUI
import ArcaVoiceKit

/// Login and logout for an app with no server. An "account" is a fully
/// separate space on this Mac — its own library, memory, keys and companion.
/// Logging out starts a brand-new space (and therefore the first-run hatch);
/// logging in is picking an existing space. Both relaunch, because the store
/// is chosen at launch.
@MainActor
enum AccountSwitcher {
    static func logOutToFreshAccount() {
        let account = AccountStore.add(displayName: L("새 친구", "New friend"), email: nil)
        AccountStore.switchTo(id: account.id)
        MacPermissionCoach.shared.relaunch()
    }

    static func logIn(to account: ArcaAccount) {
        AccountStore.switchTo(id: account.id)
        MacPermissionCoach.shared.relaunch()
    }

    static var current: ArcaAccount { AccountStore.current() }
    static var all: [ArcaAccount] { AccountStore.all() }

    /// A companion-named label for an account when it has hatched one.
    static func label(for account: ArcaAccount) -> String {
        account.displayName
    }
}

/// The sidebar's account chip: who is logged in, switch, log out.
struct AccountChip: View {
    @State private var accounts = AccountSwitcher.all
    @State private var current = AccountSwitcher.current
    @State private var confirmLogout = false

    var body: some View {
        Menu {
            Section(L("로그인된 계정", "Logged in as")) {
                Label(current.displayName, systemImage: "person.crop.circle.fill")
            }
            if accounts.count > 1 {
                Section(L("다른 계정으로 로그인", "Log in as")) {
                    ForEach(accounts.filter { $0.id != current.id }) { account in
                        Button {
                            AccountSwitcher.logIn(to: account)
                        } label: {
                            Label(account.displayName, systemImage: "person")
                        }
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmLogout = true
            } label: {
                Label(L("로그아웃 (새 시작)", "Log out (fresh start)"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(ArcaSkins.current.mid.opacity(0.25)).frame(width: 24, height: 24)
                    Text(String(current.displayName.prefix(1)))
                        .font(.system(.caption, design: .rounded, weight: .bold))
                }
                Text(current.displayName)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.borderlessButton)
        .confirmationDialog(L("로그아웃할까요?", "Log out?"), isPresented: $confirmLogout) {
            Button(L("로그아웃하고 새로 시작", "Log out and start fresh"), role: .destructive) {
                AccountSwitcher.logOutToFreshAccount()
            }
        } message: {
            Text(L("이 계정의 녹음·기억·컴패니언은 그대로 남고, 새 빈 계정으로 첫 만남부터 다시 시작해요. 여기 메뉴에서 언제든 다시 로그인할 수 있어요.",
                   "This account's recordings, memory and companion stay put. You start a new empty account from the first meeting, and can log back in from this menu anytime."))
        }
        .onAppear { accounts = AccountSwitcher.all; current = AccountSwitcher.current }
    }
}
#endif
