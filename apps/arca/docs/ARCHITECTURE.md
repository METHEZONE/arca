# ARCA Voice — Architecture & Product Design

> v0.1 — 2026-07-03. Goal 1: 녹음 → 실시간 자막 → 화자분리 최종 전사 → 회의 요약.
> 원칙: **성능과 사용성 최우선. 쓰는 게 재밌어야 한다. 구독료 없는 내 앱.**

## Product thesis

Plaud/Granola를 이기는 세 가지 축:

1. **채널 분리 캡처** — Mac에서 마이크(나)와 시스템 오디오(상대방들)를 물리적으로 분리 녹음.
   화자분리가 "추측"이 아니라 "구조"에서 시작한다. 봇 없음, 회의 참여 흔적 없음.
2. **하이브리드 전사** — 녹음 중엔 온디바이스 스트리밍 자막(즉각 반응, 무료, 오프라인),
   녹음이 끝나면 고품질 최종 패스(최고 정확도 + 무제한 화자분리). 사용자는 항상 빠르고, 결과물은 항상 정확하다.
3. **Company brain 초석** — 로컬+iCloud 우선, 하지만 모든 데이터 모델이 `SyncBackend` 추상화 뒤에 있어
   나중에 ARCA 메모리 레이어/SaaS로 그대로 열린다. 화자 voice-print가 축적되어 "이 목소리 = 김OO"를 회의를 거듭할수록 잘 맞춘다.

## Platforms

- **v1**: macOS 26 + iOS 26 동시 (SwiftUI 멀티플랫폼, 단일 코드베이스 + 플랫폼 분기)
- **v1.x**: iPadOS(자동 확보, 레이아웃 최적화), watchOS(원격 녹음기 → iPhone 싱크)
- 웹은 나중에 (SaaS 단계에서)

## Repo layout

```
apps/arca-voice/
  project.yml                 # xcodegen
  ArcaVoice/                  # 앱 타깃 (SwiftUI, macOS+iOS)
    App/                      # entry, DI, settings
    Features/
      Record/                 # 녹음 HUD, 라이브 자막
      Sessions/               # 라이브러리, 세션 상세(전사+오디오 싱크)
      Notes/                  # 노트 에디터 (Granola식 enhance)
      Speakers/               # 화자 관리, voice-print
    DesignSystem/             # 모션·컬러·타이포 토큰, 컴포넌트
  Packages/ArcaVoiceKit/      # 로컬 SPM 패키지 (플랫폼 무관 코어)
    Sources/
      Capture/                # 오디오 캡처
      Transcribe/             # ASR (live + final)
      Diarize/                # 화자분리 + voice-print
      Intelligence/           # LLM 요약·노트 강화
      Store/                  # SwiftData 모델 + sync 추상화
    Tests/
```

## Pipeline (Goal 1)

```
┌─ RECORD ────────────────────────────────────────────────┐
│ Mac:  mic (AVAudioEngine) ─┐                            │
│       system audio (CoreAudio process tap) ─┤ 채널 분리  │
│ iOS:  mic only ────────────┘  → 트랙별 파일 + 타임스탬프  │
└──────────────┬──────────────────────────────────────────┘
               │ 스트리밍 버퍼
┌─ LIVE ───────▼──────────────────────────────────────────┐
│ 온디바이스 스트리밍 ASR (채널별) → volatile/final 자막    │
│ + 사용자는 그 옆에서 러프 노트 타이핑 (타임스탬프 앵커)   │
└──────────────┬──────────────────────────────────────────┘
               │ 녹음 종료
┌─ FINAL PASS ─▼──────────────────────────────────────────┐
│ 1. 고품질 전사 (per channel)                             │
│ 2. 화자분리: mic 채널 = owner 확정,                       │
│    system 채널 = N-speaker diarization (무제한)          │
│ 3. voice-print 매칭 → 기존 화자 이름 자동 부여            │
│ 4. 병합 → 화자별 최종 전사                                │
└──────────────┬──────────────────────────────────────────┘
┌─ INTELLIGENCE▼──────────────────────────────────────────┐
│ Claude: 요약·결정사항·액션아이템 + 러프 노트 enhance      │
│ (Granola식: 내가 쓴 노트를 전사 컨텍스트로 완성)          │
└──────────────┬──────────────────────────────────────────┘
┌─ STORE/SYNC ─▼──────────────────────────────────────────┐
│ SwiftData(+CloudKit) → 기기간 동기화                     │
│ SyncBackend 프로토콜 → 미래: ARCA company brain push     │
└─────────────────────────────────────────────────────────┘
```

## Core protocols (엔진 교체 가능하게)

```swift
protocol AudioCaptureEngine {           // Capture
    func start(config: CaptureConfig) async throws -> CaptureSession
    // CaptureSession: AsyncStream<AudioChunk> per channel + 파일 기록
}

protocol LiveTranscriber {              // Transcribe (streaming)
    func transcribe(_ audio: AsyncStream<AudioChunk>, locale: Locale)
        -> AsyncThrowingStream<LiveSegment, Error>   // volatile → finalized
}

protocol FinalTranscriber {             // Transcribe (batch, 고품질)
    func transcribe(fileURL: URL, hints: TranscriptHints) async throws -> Transcript
}

protocol Diarizer {
    func diarize(fileURL: URL, transcript: Transcript) async throws -> [SpeakerTurn]
}

protocol SpeakerIdentifier {            // voice-print
    func embed(turns: [SpeakerTurn], audio: URL) async throws -> [SpeakerEmbedding]
    func match(_ e: SpeakerEmbedding, against: [KnownSpeaker]) -> SpeakerMatch?
}

protocol Summarizer {                   // Intelligence
    func summarize(_ t: AttributedTranscript, userNotes: String?, style: NoteStyle)
        async throws -> MeetingNotes
}

protocol SyncBackend {                  // Store — 지금은 CloudKit, 미래엔 ARCA brain
    func push(_ session: SessionSnapshot) async throws
    func pull(since: Date) async throws -> [SessionSnapshot]
}
```

## Accounts & multi-tenancy seams

- ARCA currently ships with a permanent `default` local account for Min's existing setup.
- `default` is a compatibility contract: Keychain, `~/.arca/connections.json`, SwiftData's existing store, sessions, and legacy `UserDefaults` keys stay exactly where they were.
- `AccountStore` persists the local registry at `~/.arca/accounts.json` and stores the selected account id in `UserDefaults.currentAccountId`.
- First run creates only the `default` account from legacy `ownerName` and `summaryEmailRecipient`; it does not move, rename, or migrate existing data.
- Non-default accounts are local-only namespaces for future users on the same machine.
- Keychain accounts become `<accountId>.<kind>` outside `default`; `default` still uses raw `ApiKeyKind` names.
- Composio connection files stay at `~/.arca/connections.json` for `default`; other accounts use `~/.arca/accounts/<id>/connections.json`.
- Account-scoped defaults use `acct.<id>.<key>` outside `default`; legacy keys remain unprefixed for `default`.
- SwiftData keeps the platform default store for `default`; other accounts use `Application Support/ArcaVoice/accounts/<id>/arca.store`.
- Session audio/files keep `Application Support/ArcaVoice/sessions` for `default`; other accounts use `Application Support/ArcaVoice/accounts/<id>/sessions`.
- The Settings account switcher records the next account and asks for app restart instead of swapping containers live.
- A future cloud auth layer should own account identity, device membership, sync tokens, and conflict policy, then map authenticated user ids onto these local account ids.
- A future sync service can plug in below `AccountStore`, scoped defaults, Keychain account naming, config URLs, SwiftData store selection, and session paths without breaking Min's local default.

## Engine decisions

(리서치 결과 반영 — 아래 "Stack decision" 섹션에 확정 기록)

- **Live ASR**: TBD — Apple SpeechAnalyzer(macOS/iOS 26 내장, 무료) vs WhisperKit
- **Final ASR**: TBD — 클라우드(diarization 내장 API) vs 로컬 대형 모델
- **Diarization**: TBD — 클라우드 내장 vs FluidAudio(온디바이스 CoreML) vs self-host pyannote
- **LLM**: Anthropic Claude 우선 (요약·노트 강화), OpenAI 키도 지원 — provider 추상화
- 모든 API 키는 사용자 소유(BYOK), Keychain 저장. 서버 없음.

## Data model (SwiftData)

- `Session` — 제목, 시각, 상태(recording/processing/ready), 소스(mac-meeting/ios-memo/import)
- `AudioAsset` — 채널(mic/system/mixed), 파일 URL, duration, 포맷
- `TranscriptSegment` — text, t0/t1, channel, speakerID?, confidence, kind(live/final)
- `Speaker` — 이름, voice embedding(들), 색상, 회의 히스토리
- `Note` — 사용자 러프 노트(타임스탬프 앵커) + enhanced 버전
- `Summary` — 구조화 요약, 결정, 액션아이템(assignee=Speaker 링크)

iCloud: SwiftData + CloudKit 미러링. 오디오 원본은 용량 때문에 로컬 + 선택적 iCloud Drive.

## UX 원칙 (재미가 스펙이다)

- 녹음 시작 = 글로벌 핫키/메뉴바 원클릭, 회의 앱 감지 시 자동 제안 (Mac)
- 라이브 자막은 **말하는 속도로 차오르는** 파형+텍스트 모션 (SpeechAnalyzer volatile 결과로 글자가 확정되며 안정화되는 애니메이션)
- 녹음 중 내가 쓰는 러프 노트 한 줄이 나중에 완성 문단으로 "피어나는" enhance 모션
- 화자는 컬러 오브로 표현, voice-print 매칭되면 오브에 이름이 스냅되는 마이크로 인터랙션
- 처리 중에도 기다림이 없게: 라이브 자막을 즉시 보여주고 최종본이 백그라운드에서 조용히 교체됨

## v1 scope (Goal 1)

- [x] 아키텍처/스캐폴드
- [ ] Mac: mic+시스템 오디오 채널 분리 녹음
- [ ] 라이브 스트리밍 자막 (ko/en)
- [ ] 최종 패스: 고품질 전사 + 무제한 화자분리 + 채널 병합
- [ ] voice-print 화자 식별 (cross-meeting)
- [ ] Claude 요약 + 노트 enhance
- [ ] 세션 라이브러리 + 전사-오디오 싱크 재생
- [ ] iPhone: 마이크 녹음 + 동일 파이프라인
- 이후: Watch 원격 녹음, iPad 레이아웃, membase/company brain push, 파일 임포트(Plaud 파일 흡수)

## Stack decision (2026-07-03 리서치 확정)

핵심 발견 두 가지:
- **한국어가 결정적 제약.** 최속 온디바이스 엔진(NVIDIA Parakeet: 유럽어 25종+일/중)은 한국어 미지원으로 탈락. Whisper 계열 + Apple 네이티브로 수렴.
- **화자분리는 acoustic — 언어 무관.** 한국어 이슈는 ASR 레이어에만 존재. 두 결정을 분리한다.

| 레이어 | 기본 (v1) | 대안/폴백 |
|---|---|---|
| Live ASR (Mac·iPhone) | **Apple SpeechTranscriber** (macOS/iOS 26 내장) | WhisperKit 스트리밍 (ko/en 코드스위칭 시), Moonshine v2 |
| Final ASR + 화자분리 | **OpenAI `gpt-4o-transcribe-diarize`** (BYOK) | ElevenLabs Scribe v2 / 로컬 WhisperKit large-v3-turbo + FluidAudio |
| 로컬 화자분리 | **FluidAudio** (pyannote community-1 CoreML, Apache 2.0) | pyannoteAI precision-2 API (프리미엄 티어) |
| Voice-print | **FluidAudio WeSpeaker 임베딩** — 온디바이스, 로컬 프로필 저장 | pyannoteAI Voiceprint/Identify API |
| 요약·노트 강화 | **Claude** (Anthropic BYOK) | OpenAI |

### 근거

**Live = Apple SpeechTranscriber.** `volatileResults` → finalized 스트리밍 API가 우리가 원하는 "글자가 확정되며 안정화되는" UX 그 자체. 한국어 네이티브, 모델은 OS가 관리(앱 용량 0), ANE 최적화로 배터리 최소 — iPhone 상시 사용이 가능한 유일한 옵션. 정확도는 mid-tier(long-form EN WER ~14%)지만 live 레이어엔 충분하고, 최종본은 어차피 final pass가 교체함. 약점: 문장 내 ko/en 코드스위칭 — 실사용에서 거슬리면 WhisperKit 스트리밍(~200ms 첫 단어, near-large 정확도)으로 교체 가능하게 `LiveTranscriber` 프로토콜 뒤에 둠.

**Final = gpt-4o-transcribe-diarize 기본.** 한국어 + 무제한급 화자분리 + 타임스탬프를 API 한 번에, ~$0.36/시간(회의 1시간에 500원). 사용자 키(BYOK)라 우리 인프라 비용 0, 서버 없음. known_speaker_references 4명 제한은 무시 — 화자 식별은 우리가 로컬 voice-print로 함(아래). 프라이버시 모드: WhisperKit large-v3-turbo(한국어 CER ~5.6%, 온디바이스 최강) + FluidAudio 오프라인 diarization(pyannote community-1 포트, 화자 수 무제한)으로 완전 로컬 처리.

**Voice-print = 온디바이스 WeSpeaker.** 회의 종료 후 화자별 임베딩 추출 → 로컬 벡터 저장 → 코사인 매칭으로 기존 인물 자동 명명, 미매칭 시 사용자에게 "이 목소리 누구?" 1회 질문. 클라우드 의존 없음, 인원 무제한, 프라이빗. **이게 Granola를 이기는 기능** — "Speaker 1/2"가 아니라 회의를 거듭할수록 이름을 기억하는 앱.

**채널 분리의 가치 재확인.** mic=나 / system=상대방들 분리는 Me/Others 구분을 100% 정확·무료로 해결. 화자분리는 system 채널 안의 "상대방들"을 나누는 데만 필요 → 문제 크기 자체가 줄어듦.

### 캡처 아키텍처 (확정)

**macOS: Core Audio Process Tap (macOS 14.4+), ScreenCaptureKit 아님.**
- SCK는 화면녹화 권한 + 메뉴바 인디케이터가 뜸. Process tap은 전용 TCC(`NSAudioCaptureUsageDescription`)로 오디오만 깔끔하게.
- 두 개의 독립 경로: AVAudioEngine 마이크 + 시스템 출력 process tap → 채널 분리 유지.
- **AEC 불필요**: 시스템 오디오를 스피커 이전 단계에서 디지털로 탭하므로 음향 에코가 원천적으로 없음. (Granola는 합쳐진 스트림이라 이걸 못함 — 우리의 구조적 우위.)
- 함정들(레퍼런스로 검증됨): `exclusive` 플래그는 락이 아니라 스코프 셀렉터(잘못 만지면 무음), AVAudioEngine은 CATap aggregate로 재타깃 불가(noErr 반환하면서 기본 입력을 계속 읽음) → `AudioDeviceCreateIOProcIDWithBlock` + 비-nil DispatchQueue로 IOProc 직접 등록, aggregate는 실제 출력장치를 main sub-device로 + tap을 sub-tap으로 + TapAutoStart, 서명된 바이너리여야 TCC 프롬프트가 뜸, mono/interleaved 동적 처리, teardown 순서 엄수.

**iOS: 마이크 전용이 현실적 한계** (OS가 시스템 오디오 캡처를 금지). iPhone = 대면 회의·음성메모 캡처 + 컴패니언/리뷰 서피스. 화상회의 캡처는 Mac의 역할. 전화 녹음은 약속하지 않는다(아무도 못 함).

**Watch: 원격 트리거** (녹음 시작/정지/"이 순간 플래그") — Watch→iPhone 라이브 오디오 스트리밍은 2026년에도 신뢰성이 없음. Watch가 iPhone/Mac 녹음을 제어.

**요약 엔진 보강**: Apple Foundation Models(온디바이스)를 무료·오프라인 요약 티어로, Claude를 고품질 티어로.

### 참고한 레퍼런스
- **FluidInference/swift-scribe** (MIT) — SwiftUI+SpeechAnalyzer+FluidAudio+SwiftData 네이티브 레퍼런스 앱. 앱 셸·라이브 전사 UI·화자 컬러 에디터 패턴을 채굴. 시스템 오디오 탭은 없음(우리가 추가하는 부분).
- insidegui/AudioCap, makeusabrew/audiotee — process tap 구현 레퍼런스
- FluidAudio: FluidInference/FluidAudio (Apache 2.0, ~2.4k★, diarization+VAD+임베딩 CoreML, LS-EEND 스트리밍 10화자)
- WhisperKit → argmaxinc/argmax-oss-swift v1.0 (MIT)
- fastrepl/anarlog(ex-Hyprnote, MIT ~8.8k★) — 제품 UX·BYO-LLM 노트 파이프라인만 채굴(스택은 Tauri라 무시), Zackriya-Solutions/meetily(MIT ~13.7k★) — 오디오 더킹/클리핑 로직 참고. VoiceInk는 GPL이라 코드 링크 금지.
- Wispr Flow는 클라우드+후처리 조합 (온디바이스 마법 아님) — 우리 하이브리드가 같은 체감 품질에 프라이버시 우위 가능

### Granola/Plaud를 이기는 UX 3종 (리서치 확정)
1. **Enhance 루프의 진화** — Granola의 #1 사랑받는 기능(러프 노트 × 전사 병합)을 라이브·연속으로 돌리고, ARCA 크로스소스 컨텍스트(캘린더·이전 회의·Slack)까지 주입. Granola는 transcript-only.
2. **봇 없는 채널 분리 캡처를 신뢰 스토리로** — "창에 봇이 안 들어옴" + 나/상대 구분이 구조적으로 정확 + 상대방 개별 분리까지 (Granola는 물리적으로 불가능).
3. **목적지별 출력 포매팅** — 같은 회의를 Slack 요약/정중한 이메일/액션아이템 필드로 각각 렌더 + 개인 사전(이름·약어 정확 전사).
