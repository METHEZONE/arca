#if os(macOS)
import SwiftUI
import ArcaVoiceKit

/// The first minutes after hatching: ARCA rides along in a corner card and
/// walks the owner through the five places, then asks for a first recording
/// so the whole loop — talk, stop, read the notes — happens once with a guide
/// present. Every step can be skipped; the tour never comes back on its own.
struct CompanionTour: View {
    static let doneKey = "companionTourDone"

    let companionName: String
    let onFocus: (ArcaSection?) -> Void
    let onStartRecording: () -> Void
    let onFinish: () -> Void

    @State private var step = 0

    private struct Step {
        let section: ArcaSection?
        let title: String
        let body: String
        let cta: String?
    }

    private var steps: [Step] {
        [
            Step(section: nil,
                 title: L("안녕, 저 \(companionName)이에요", "Hi, I'm \(companionName)"),
                 body: L("1분만 같이 둘러볼까요? 언제든 건너뛸 수 있어요.", "Want a one-minute walk-through? You can skip anytime."),
                 cta: nil),
            Step(section: .home,
                 title: L("홈 — 제가 사는 곳", "Home — where I live"),
                 body: L("저를 누르면 바로 녹음이 시작돼요. 밑에는 오늘 기억한 것들과 할 일이 모여요. 저는 가끔 간식도 먹고 코드도 두드려요.",
                         "Tap me to start recording. Below are today's memories and to-dos. I snack and type sometimes."),
                 cta: nil),
            Step(section: .memory,
                 title: L("메모리 — 제 머릿속", "Memory — my head"),
                 body: L("회의·대화에서 배운 것들이 색깔 캐릭터로 살아요. 하나를 누르면 전문과 연결된 생각이 보이고, '인사이트 엮기'로 숨은 연결을 찾아요.",
                         "What I learn lives here as little characters. Click one for the full text and its links; 'Weave insights' finds hidden connections."),
                 cta: nil),
            Step(section: .day,
                 title: L("하루 — 오늘의 흐름", "Day — how today went"),
                 body: L("화면 기록을 허용하면 5분마다 살짝 보고, 저녁에 하루 리포트를 써드려요.",
                         "With Screen Recording allowed I glance every five minutes and write tonight's report."),
                 cta: nil),
            Step(section: .wiki,
                 title: L("위키 — 당신에 대한 책", "Wiki — the book on you"),
                 body: L("기억이 쌓이면 여기서 한 번에 정리해요. 옵시디언이 없어도 ~/Documents/ARCA에 마크다운으로 남아요.",
                         "As memory grows I write it up here. It's also plain markdown in ~/Documents/ARCA."),
                 cta: nil),
            Step(section: .library,
                 title: L("라이브러리 — 회의록", "Library — your notes"),
                 body: L("모든 녹음의 전사와 요약이 여기 있어요. 노트 안에서 복사·전송·공유하고, 저와 그 회의에 대해 대화할 수 있어요.",
                         "Every recording's transcript and notes. Copy, send, share from inside a note, or talk to me about it."),
                 cta: nil),
            Step(section: .library,
                 title: L("한 번 해볼까요?", "Shall we try one?"),
                 body: L("30초만 아무 말이나 해보세요 — 오늘 할 일이나 방금 회의 내용. 정지하면 제가 TL;DR·결정·액션 아이템으로 정리해 드릴게요.",
                         "Talk for 30 seconds — today's plan, the last meeting. Stop, and I'll write the TL;DR, decisions and action items."),
                 cta: L("첫 녹음 시작", "Start first recording")),
        ]
    }

    var body: some View {
        let current = steps[min(step, steps.count - 1)]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ArcaFace(mood: step == steps.count - 1 ? .listening : .happy, size: 54, halo: true, interactive: true)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.title)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Text(current.body)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<steps.count, id: \.self) { i in
                        Capsule().fill(i <= step ? ArcaSkins.current.mid : .white.opacity(0.15))
                            .frame(width: i == step ? 16 : 6, height: 5)
                    }
                }
                Spacer()
                Button(L("건너뛰기", "Skip")) { finish() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                if let cta = current.cta {
                    Button {
                        finish()
                        onStartRecording()
                    } label: {
                        Label(cta, systemImage: "waveform")
                            .font(.system(.callout, design: .rounded, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(ArcaSkins.current.mid, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.arcaPress)
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.3)) { step += 1 }
                        onFocus(steps[min(step, steps.count - 1)].section)
                    } label: {
                        Text(L("다음", "Next"))
                            .font(.system(.callout, design: .rounded, weight: .bold))
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(ArcaSkins.current.mid, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.arcaPress)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Color(red: 0.08, green: 0.09, blue: 0.15).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ArcaSkins.current.mid.opacity(0.45)))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .onAppear { onFocus(nil) }
    }

    private func finish() {
        AccountDefaults.set(true, for: Self.doneKey)
        onFocus(nil)
        onFinish()
    }
}
#endif
