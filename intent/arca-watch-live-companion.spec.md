# Spec — 워치 라이브 컴패니언

Source: `intent/arca-watch-live-companion.intent.md`. 브랜치 `watch-live-main` (origin/main 기반). 작성 2026-09-17.

## 1. Requirements → 구현

| R | 요구 | 어디 |
|---|---|---|
| R1 | 세 제스처 상태기계 `WatchMode { idle, talking, recording, memo }` | `ArcaVoiceWatch/FaceRecordView.swift` |
| R2 | 상태별 링 색·눈·몸 모션·캡션 | 같은 파일 (`SpiritBody`에 `lean`, `speakingLevel`) |
| R3 | 실시간 대화 클라이언트 (WebSocket → OpenAI Realtime GA) | `ArcaVoiceWatch/WatchLiveTalk.swift` |
| R4 | 임시 키는 아이폰이 발급 (`sendMessage` 요청/응답) | `WatchSync.requestRealtimeSecret` ↔ `PhoneWatchSync` |
| R5 | 아이폰 발급기: BYOK(`KeychainStore .openAI`) 또는 ARCA Cloud | `ArcaVoice/App/RealtimeSecretMinter.swift`, `app/api/arca/cloud/realtime/secret/route.ts` |
| R6 | 대화 전사 → 아이폰 `ChatLogEntry`(conversationId `watch-yyyy-MM-dd`) | `WatchSync.send(talk:)` → `PhoneWatchSync.didReceiveUserInfo` |
| R7 | 빠른 메모 = 기존 녹음 파이프라인 + `kind: memo` 메타 → 제목 "빠른 메모" | `WatchRecorder`, `WatchSync.send(file:)`, `PhoneWatchSync.didReceive file` |
| R8 | 할 일 페이지: applicationContext `todos` 수신, 완료 시 `todoDone` 회신 | `WatchTodoStore.swift`, `TodoListView.swift`, `PhoneWatchSync.sendTodos` |
| R9 | 설정(기어): 언어·대화 음성·진동 | `WatchSettingsView.swift` |
| R10 | 워치 기본 언어 한국어, 영어 문구 제거 | `WatchLocalization.swift`, 각 뷰 |

## 2. Design

### 2.1 제스처 (watchOS SwiftUI)
- `.onTapGesture(count: 2)` 를 먼저, `.onTapGesture` 를 뒤에 — SwiftUI가 더블탭 대기 후 싱글을 확정한다.
- 꾹: `.onLongPressGesture(minimumDuration: 0.45, pressing:perform:)`. `perform`에서 memo 시작, `pressing == false`이면 memo 종료·저장. 탭은 `perform`을 못 지나므로 메모를 열지 않는다.
- 다른 모드가 켜져 있으면 제스처는 그 모드를 닫는 쪽으로만 동작한다(대화 중 더블탭 → 무시, 캡션으로 안내).

### 2.2 모션 (상태 → 표현)
| 상태 | 링 | 눈 | 몸 | 캡션 |
|---|---|---|---|---|
| idle | 없음 | 생활 루프(깜빡·곁눈·졸기) | 가끔 폴짝 | "탭 대화 · 두 번 녹음 · 꾹 메모" |
| talking·듣는 중 | 파랑 펄스 | 위로 살짝(당신을 봄) | 숨쉬기 | "듣고 있어요" |
| talking·말하는 중 | 파랑 고정 | 행복 아크 | `speakingLevel`에 비례해 1.0~1.12 스케일 | ARCA 말 자막 1줄 |
| recording | 초록 펄스 | 행복 아크 | 숨쉬기 | 타이머 |
| memo | 주황 | 크게 뜬 눈 | 8° 기울기(귀 기울임) | "듣고 있어요 — 손을 떼면 저장" |

### 2.3 Realtime (GA WebSocket)
- `wss://api.openai.com/v1/realtime?model=gpt-realtime`, `Authorization: Bearer <ek_…>`.
- 시작 시 `session.update`: `{type: realtime, instructions, audio: {input: {format: {type: audio/pcm, rate: 24000}, turn_detection: {type: server_vad}, transcription: {model: gpt-4o-mini-transcribe}}, output: {format: {type: audio/pcm, rate: 24000}, voice: marin}}}`.
- 마이크: `AVAudioEngine.inputNode` 탭 → `AVAudioConverter` → Int16 mono 24 kHz → 100 ms마다 `input_audio_buffer.append` (base64).
- 재생: `response.output_audio.delta` → Int16→Float32 → `AVAudioPlayerNode`(24 kHz mono) 스케줄. `input_audio_buffer.speech_started` 수신 시 재생 큐 비움(끼어들기).
- 전사: `conversation.item.input_audio_transcription.completed`(user), `response.output_audio_transcript.done`(assistant) → `turns` 누적.
- 종료: 탭 → 소켓 close, 세션 비활성, `turns`를 아이폰에 전송.
- 실패 문구: 아이폰 미도달 → "아이폰이 근처에 있어야 대화할 수 있어요"; 키 없음 → "아이폰 ARCA에 OpenAI 키나 초대 코드가 필요해요".

### 2.4 아이폰 발급기
`RealtimeSecretMinter.mint(instructions:) async throws -> (value: String, expiresAt: Date)`
1. `KeychainStore.get(.openAI)` 있으면 `POST https://api.openai.com/v1/realtime/client_secrets` body `{expires_after: {anchor: created_at, seconds: 600}, session: {type: realtime, model: gpt-realtime, instructions, audio: {output: {voice: marin}}}}`.
2. 없고 `ArcaCloud.inviteToken` 있으면 `POST {ArcaCloud.baseURL}/realtime/secret` (`x-api-key: <invite>`), 서버가 같은 요청을 `OPENAI_API_KEY`로 대신 보낸다.
3. `instructions` = ARCA 워치 페르소나(한국어, 짧게, 1~2문장) + `MemoryPrompt.systemBlock` 요약(있으면).

### 2.5 applicationContext 합치기
지금은 `vitals`가 context 전체를 덮어쓴다. 앞으로 `["vitals": {...}, "todos": [...]]` 한 사전으로 보내고, 아이폰이 마지막 값을 들고 있다가 어느 쪽이 바뀌어도 둘을 함께 보낸다. 워치는 두 키를 각각 적용(구형 `type: vitals` 모양도 계속 읽음).

## 3. 검증
- 빌드: `xcodebuild -scheme ARCA -destination generic/platform=iOS` (워치 앱 임베드) + macOS.
- 실기기: TestFlight 빌드로 민성이 AC-1~6 확인. 시뮬레이터는 마이크·WCSession이 없어 대화 검증 불가.
- 단위: `WatchLiveTalk` 이벤트 파서(서버 이벤트 JSON → 상태 전이) 는 순수 함수로 두어 테스트 가능하게.
