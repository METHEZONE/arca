#if os(macOS)
import SwiftUI
import ArcaVoiceKit

/// The first minutes after hatching: the floating ARCA flies to each place in
/// the app and explains it in a speech bubble, then asks for a first 30-second
/// recording so the whole loop happens once with a guide present. Skippable;
/// shown once per account.
enum CompanionTour {
    static let doneKey = "companionTourDone"

    static func steps(companionName: String) -> [TourDirector.Step] {
        [
            .init(section: nil,
                  title: L("안녕, 저 \(companionName)이에요", "Hi, I'm \(companionName)"),
                  body: L("1분만 같이 둘러볼까요? 제가 앞장설게요 — 언제든 건너뛸 수 있어요.", "Want a one-minute walk-through? I'll lead — skip anytime."),
                  cta: nil),
            .init(section: .home,
                  title: L("홈 — 제가 사는 곳", "Home — where I live"),
                  body: L("큰 저를 누르면 바로 녹음이 시작돼요. 밑에는 오늘 기억한 것들과 할 일이 모여요. 저는 가끔 간식도 먹고 코드도 두드려요.",
                          "Tap the big me to start recording. Below are today's memories and to-dos. I snack and type sometimes."),
                  cta: nil),
            .init(section: .memory,
                  title: L("메모리 — 제 머릿속", "Memory — my head"),
                  body: L("회의·대화에서 배운 것들이 색깔 캐릭터로 살아요. 하나를 누르면 전문과 연결된 생각이 보이고, '인사이트 엮기'로 숨은 연결을 찾아요.",
                          "What I learn lives here as little characters. Click one for the full text and its links; 'Weave insights' finds hidden connections."),
                  cta: nil),
            .init(section: .day,
                  title: L("하루 — 오늘의 흐름", "Day — how today went"),
                  body: L("화면 기록을 허용하면 5분마다 살짝 보고, 저녁에 하루 리포트를 써드려요.",
                          "With Screen Recording allowed I glance every five minutes and write tonight's report."),
                  cta: nil),
            .init(section: .wiki,
                  title: L("위키 — 당신에 대한 책", "Wiki — the book on you"),
                  body: L("기억이 쌓이면 여기서 한 번에 정리해요. 옵시디언이 없어도 ~/Documents/ARCA에 마크다운으로 남아요.",
                          "As memory grows I write it up here. It's also plain markdown in ~/Documents/ARCA."),
                  cta: nil),
            .init(section: .library,
                  title: L("라이브러리 — 회의록", "Library — your notes"),
                  body: L("모든 녹음의 전사와 요약이 여기 있어요. 노트 안에서 복사·전송·공유하고, 저와 그 회의에 대해 대화할 수 있어요.",
                          "Every recording's transcript and notes. Copy, send, share from inside a note, or talk to me about it."),
                  cta: nil),
            .init(section: .library,
                  title: L("한 번 해볼까요?", "Shall we try one?"),
                  body: L("30초만 아무 말이나 해보세요 — 오늘 할 일이나 방금 회의 내용. 정지하면 제가 TL;DR·결정·액션 아이템으로 정리해 드릴게요.",
                          "Talk for 30 seconds — today's plan, the last meeting. Stop, and I'll write the TL;DR, decisions and action items."),
                  cta: L("첫 녹음 시작", "Start first recording")),
        ]
    }
}
#endif
