import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Everything ARCA can do, as a skill tree: what each skill does, whether
/// it's awake (its key or connector is in place), how often it's been used,
/// and a way to try it right now. Usage leveles the skill up — an honest
/// mirror of how the companion has actually been working for you.
struct SkillsView: View {
    struct Skill: Identifiable {
        let id: String
        let name: String
        let blurb: String
        let symbol: String
        let tint: Color
        let event: CompanionProgress.Event?
        let requirement: Requirement
        let tryPrompt: String?

        enum Requirement { case none, anthropic, openAI, connector(String), screenRecording }
    }

    @State private var progress = CompanionProgress.shared
    @State private var hub = ConnectorHub()
    var onTry: ((String) -> Void)? = nil

    private var skills: [Skill] {
        [
            Skill(id: "brain", name: L("브레인 — 기억 엮기", "Brain — weave memory"),
                  blurb: L("회의·대화에서 배운 것을 하나의 기억 그래프로 엮고, 숨은 연결을 찾아요.", "Weaves what it learns into one memory graph and finds hidden links."),
                  symbol: "brain.head.profile", tint: Color(hex: 0x9B7BFF), event: .insightWoven, requirement: .anthropic,
                  tryPrompt: L("내 기억에서 최근 프로젝트 관련 내용을 찾아서 정리해줘", "Search my memory for recent project notes and organize them")),
            Skill(id: "ears", name: L("귀 — 회의 요약", "Ears — meeting notes"),
                  blurb: L("녹음을 전사하고 TL;DR·결정·액션 아이템으로 정리해요.", "Transcribes recordings into a TL;DR, decisions and action items."),
                  symbol: "waveform", tint: Color(hex: 0xFF7A1A), event: .meetingSummarized, requirement: .anthropic, tryPrompt: nil),
            Skill(id: "diarize", name: L("화자 분리", "Speaker separation"),
                  blurb: L("여러 사람이 말해도 누가 말했는지 가려내요.", "Tells speakers apart in a room."),
                  symbol: "person.2.wave.2", tint: Color(hex: 0xFF6FA8), event: nil, requirement: .openAI, tryPrompt: nil),
            Skill(id: "eyes", name: L("눈 — 하루 리포트", "Eyes — day report"),
                  blurb: L("5분마다 화면을 살짝 보고 저녁에 하루의 흐름을 리포트해요.", "Glances at the screen and reports how the day flowed each evening."),
                  symbol: "eye.fill", tint: Color(hex: 0x4C8DFF), event: .dayReport, requirement: .screenRecording, tryPrompt: nil),
            Skill(id: "todo", name: L("할 일 맡기기", "Hand off to-dos"),
                  blurb: L("대화에서 할 일을 만들고, 루틴은 대신 처리해요.", "Creates to-dos from chat and handles the routine ones."),
                  symbol: "checklist", tint: Color(hex: 0x3DC26F), event: .todoDone, requirement: .none,
                  tryPrompt: L("내일 오전까지 IR 덱 초안 다시 보기 할 일 만들어줘", "Create a to-do to review the IR deck draft by tomorrow morning")),
            Skill(id: "web", name: L("웹 검색", "Web search"),
                  blurb: L("최신 정보가 필요하면 직접 검색해서 근거를 붙여요.", "Searches the web and cites sources when something is current."),
                  symbol: "magnifyingglass", tint: Color(hex: 0xFFC531), event: nil, requirement: .anthropic,
                  tryPrompt: L("오늘 환율(USD/KRW) 확인해서 알려줘", "Check today's USD/KRW rate")),
            Skill(id: "notes", name: L("문서 작성", "Write documents"),
                  blurb: L("리포트·초안을 마크다운 노트로 만들어 볼트에 저장해요.", "Turns reports and drafts into markdown notes in your vault."),
                  symbol: "doc.badge.plus", tint: Color(hex: 0x2ED3DE), event: .noteSaved, requirement: .anthropic,
                  tryPrompt: L("최근 회의 3개를 바탕으로 주간 리포트를 써서 노트로 저장해줘", "Write a weekly report from my last three meetings and save it as a note")),
            Skill(id: "browser", name: L("브라우저 작업", "Browser tasks"),
                  blurb: L("내 브라우저 안에서 여러 단계 작업을 대신 해요.", "Runs multi-step tasks inside your own browser."),
                  symbol: "globe", tint: Color(hex: 0x477EE9), event: .browserTask, requirement: .none, tryPrompt: nil),
            Skill(id: "gmail", name: L("메일 보내기", "Send email"),
                  blurb: L("회의록을 메일로 보내고, 답장 초안을 만들어요.", "Emails notes and drafts replies."),
                  symbol: "envelope", tint: Color(hex: 0xEA4335), event: nil, requirement: .connector("GMAIL"), tryPrompt: nil),
            Skill(id: "calendar", name: L("일정 등록", "Calendar"),
                  blurb: L("대화에서 바로 일정을 만들어요 — 되묻지 않고.", "Creates events straight from chat — no confirmation loop."),
                  symbol: "calendar", tint: Color(hex: 0x34A853), event: nil, requirement: .connector("GOOGLECALENDAR"),
                  tryPrompt: L("내일 오후 3시 팀 싱크 1시간 잡아줘", "Book a one-hour team sync tomorrow at 3 PM")),
        ]
    }

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(skills) { skill in
                        SkillCard(skill: skill, awake: isAwake(skill), uses: skill.event.map(progress.count) ?? 0) {
                            if let prompt = skill.tryPrompt { onTry?(prompt) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.09).ignoresSafeArea())
        .task { await hub.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ArcaFace(mood: .happy, size: 64, halo: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("스킬", "Skills"))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(L("Lv.\(progress.level) · 쓸수록 자라요. 잠긴 스킬은 키나 연결 하나로 깨어나요.",
                       "Lv.\(progress.level) · Grows with use. Locked skills wake with one key or connection."))
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                LevelStrip(progress: progress)
            }
            Spacer()
        }
    }

    private func isAwake(_ skill: Skill) -> Bool {
        switch skill.requirement {
        case .none: return true
        case .anthropic: return KeychainStore.get(.anthropic) != nil
        case .openAI: return KeychainStore.get(.openAI) != nil
        case .connector(let slug): return hub.accounts[slug] != nil
        case .screenRecording: return MacPermission.screenRecording.isGranted && (UserDefaults.standard.object(forKey: "dayTrackerEnabled") as? Bool ?? false)
        }
    }
}

private struct SkillCard: View {
    let skill: SkillsView.Skill
    let awake: Bool
    let uses: Int
    let onTry: () -> Void

    private var skillLevel: Int { uses == 0 ? 0 : min(5, 1 + Int(log2(Double(uses) + 1))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(skill.tint.opacity(awake ? 0.25 : 0.08)).frame(width: 40, height: 40)
                    Image(systemName: awake ? skill.symbol : "lock.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(awake ? skill.tint : .white.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.system(.headline, design: .rounded))
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { i in
                            Image(systemName: i < skillLevel ? "star.fill" : "star")
                                .font(.system(size: 9))
                                .foregroundStyle(i < skillLevel ? skill.tint : .white.opacity(0.2))
                        }
                        if uses > 0 {
                            Text(L("\(uses)회", "\(uses)×")).font(.caption2).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                Spacer()
            }
            Text(skill.blurb).font(.callout).foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(awake ? .green : .orange)
                Spacer()
                if awake, skill.tryPrompt != nil {
                    Button(action: onTry) {
                        Label(L("써보기", "Try it"), systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(skill.tint.opacity(0.22), in: Capsule())
                            .foregroundStyle(skill.tint)
                    }
                    .buttonStyle(.arcaPress)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(awake ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(awake ? skill.tint.opacity(0.3) : .white.opacity(0.06)))
    }

    private var statusText: String {
        if awake { return L("깨어 있음", "Awake") }
        switch skill.requirement {
        case .anthropic: return L("Anthropic 키 필요 · 설정", "Needs Anthropic key · Settings")
        case .openAI: return L("OpenAI 키 필요 · 설정", "Needs OpenAI key · Settings")
        case .connector(let slug): return L("\(slug.capitalized) 연결 필요 · 커넥터", "Connect \(slug.capitalized) · Connectors")
        case .screenRecording: return L("화면 기록 권한 + 하루 기록 켜기", "Screen Recording + Day log on")
        case .none: return L("깨어 있음", "Awake")
        }
    }
}

/// Level + XP bar + coins, shared by Skills and Shop headers.
struct LevelStrip: View {
    let progress: CompanionProgress
    var body: some View {
        HStack(spacing: 10) {
            Text("Lv.\(progress.level)")
                .font(.system(.caption, design: .rounded, weight: .heavy))
                .foregroundStyle(ArcaFace.ember)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(ArcaFace.ember)
                        .frame(width: geo.size.width * CGFloat(progress.xpIntoLevel) / CGFloat(progress.xpPerLevel))
                }
            }
            .frame(width: 160, height: 8)
            Text("\(progress.xpIntoLevel)/\(progress.xpPerLevel) XP")
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            Label("\(progress.coins)", systemImage: "circle.hexagongrid.circle.fill")
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color(hex: 0xFFC531))
        }
    }
}
