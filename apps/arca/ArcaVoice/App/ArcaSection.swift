import SwiftUI
import ArcaVoiceKit

/// The one list of places ARCA has.
///
/// It exists because the Mac and the iPhone drifted into being two products: the
/// Mac grew 하루 and 위키, the iPhone grew 할 일 and 챗, and the same idea ended up
/// with different names, icons, and orders on each side. Titles and symbols now
/// come from here so that can't silently happen again — if a section exists at
/// all, it is called the same thing in both apps.
///
/// Navigation *chrome* still differs (a Mac sidebar, an iPhone tab bar) because
/// that's what each platform expects. What must not differ is which sections
/// exist and what they're called.
enum ArcaSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case condition
    case tasks
    case memory
    case day
    case wiki
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L("홈", "Home")
        case .condition: return L("컨디션", "Condition")
        case .tasks: return L("할 일", "Tasks")
        case .memory: return L("메모리", "Memory")
        case .day: return L("하루", "Day")
        case .wiki: return L("위키", "Wiki")
        case .library: return L("라이브러리", "Library")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "sparkles"
        case .condition: return "bolt.heart"
        case .tasks: return "checklist"
        case .memory: return "point.3.connected.trianglepath.dotted"
        case .day: return "sun.horizon"
        case .wiki: return "book.closed"
        case .library: return "waveform"
        }
    }

    /// One line explaining what lives here, used on the entry cards.
    var blurb: String {
        switch self {
        case .home: return L("ARCA에게 말 걸고, 바로 녹음하기", "Talk to ARCA, or start recording")
        case .condition: return L("몰입 준비도·수면·스트레스", "Readiness · Sleep · Stress")
        case .tasks: return L("ARCA가 처리 중인 것과 남은 것", "What ARCA is handling, and what's left")
        case .memory: return L("ARCA가 당신에 대해 아는 것", "What ARCA knows about you")
        case .day: return L("오늘 무엇에 시간을 썼는지", "Where your time went today")
        case .wiki: return L("ARCA가 기록한 당신의 이야기", "Your story, as ARCA wrote it down")
        case .library: return L("녹음·전사·회의록", "Recordings · transcripts · notes")
        }
    }

    /// Which device actually produces this section's raw material.
    ///
    /// This is the honest answer to "왜 맥에만 보이지?" — some of it genuinely can
    /// only be recorded on one machine. Where that's true, the other platform
    /// shows the relayed result plus a line saying where it came from, instead of
    /// hiding the section and looking like a different app.
    var recordedOn: Recorder {
        switch self {
        case .day: return .macOnly
        case .condition: return .phoneOnly
        case .home, .tasks, .memory, .wiki, .library: return .everywhere
        }
    }

    enum Recorder: Sendable {
        case everywhere
        /// The Mac sees the app-switch timeline and takes the snapshots.
        case macOnly
        /// Only the iPhone can read Apple Health.
        case phoneOnly

        /// Where this data is captured, phrased for whichever device is asking.
        var note: String? {
            #if os(macOS)
            switch self {
            case .everywhere: return nil
            case .macOnly: return nil
            case .phoneOnly: return L("아이폰이 측정해서 이 맥으로 보냅니다",
                                      "Your iPhone measures this and sends it to this Mac")
            }
            #else
            switch self {
            case .everywhere: return nil
            case .macOnly: return L("맥이 기록해서 이 아이폰으로 보냅니다",
                                    "Your Mac records this and sends it to this iPhone")
            case .phoneOnly: return nil
            }
            #endif
        }
    }

    /// The sections that get a tab of their own on the iPhone. Five, because a
    /// sixth would push the rest behind a system "More" tab and bury them.
    static let phoneTabs: [ArcaSection] = [.home, .condition, .tasks, .memory, .library]

    /// Reachable from the iPhone home instead of a tab — but present, named
    /// identically, and showing the same data as on the Mac.
    static let phoneSecondary: [ArcaSection] = [.day, .wiki]

    /// The Mac sidebar order. Todos keep their permanent right-hand rail there,
    /// which is why `.tasks` isn't in the list.
    static let macSidebar: [ArcaSection] = [.home, .condition, .memory, .day, .wiki, .library]
}
