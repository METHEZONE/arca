# 스크린샷 Handoff (아이폰 → 맥)

## 왜 만들었나

아이폰에서 스크린샷을 찍으면 ARCA가 즉시 그 내용을 읽어 요약하고 메모리에 저장한다. 문제는 그다음이었다 — 결과가 폰 안에만 갇혀 있었고, 일정으로 만들어야 할 항목이 있어도 "만들까요?"라고 물어보는 창이 없었다. 이 기능은 두 가지를 더한다.

1. 스크린샷을 읽자마자 **Handoff로 맥에 ARCA 아이콘을 띄운다** (Dock 우측 하단 / 잠금화면). 클릭하면 방금 폰에서 읽은 내용이 맥에서 바로 열린다.
2. 그 화면에서, 액션 아이템에 날짜가 있으면(회의 초대장, 예약 확인, 마감일 스크린샷 등) **"지금 일정 만들어줄까?"** 버튼을 보여준다. 없으면 그냥 "열기"만 보여준다.

메모리 저장(SwiftData에 세션+요약 저장)은 항상 자동이다 — 확인이 필요한 건 캘린더에 실제 이벤트를 만드는 것뿐이다.

## 왜 이미지가 아니라 id만 건너가나

`NSUserActivity.userInfo`는 진짜 페이로드를 태우라고 있는 자리가 아니고, Handoff 전송 자체가 작고 best-effort다. 그래서 Handoff activity에는 `RecordingSession.directoryName`(안정적인 세션 id) 하나와 `hasSchedule` 플래그만 담는다. 실제 제목/요약/액션아이템은 이미 폰에서 저장한 `RecordingSession`에 있고, 기존 `RelaySync`(GitHub 릴레이 기반 폰↔맥 동기화)가 나머지를 옮긴다. 맥은 Handoff를 받으면 60초 주기 릴레이 루프를 기다리지 않고 즉시 `syncNow()`를 몇 번 반복 호출해 세션이 도착할 때까지 짧게 폴링한다.

## 흐름

```
iPhone                                              Mac
──────                                              ───
스크린샷 감지 (userDidTakeScreenshotNotification)
  → Photos에서 최신 스크린샷 로드
  → ClaudeVisionPlanner.plan() (due 필드 추출 포함)
  → RecordingSession + SessionNote 저장 (메모리)
  → RelaySync.scheduleSync(after: 1)  ─────────────→  GitHub 릴레이 (sessions/*.json)
  → NSUserActivity(.screenshot-review).becomeCurrent()
                                                        Handoff 아이콘 클릭
                                                          → onContinueUserActivity
                                                          → RelaySync.syncNow() 폴링 (최대 6회 × 2초)
                                                          → NotchAgent.presentHandoffReview(session:)
                                                          → 날짜 있는 항목 있으면 "일정 만들기" 버튼
                                                          → 없으면 "열기"만
```

## 손댄 파일

- `Packages/ArcaVoiceKit/Sources/ArcaVoiceCore/HandoffTypes.swift` — activity type 문자열 + userInfo 키 (신규)
- `Packages/ArcaVoiceKit/Sources/Intelligence/ClaudeVisionPlanner.swift` — 액션 아이템에 `due` 필드 추출 추가, `CapturePlan.needsSchedule`/`schedulableActionItems`
- `ArcaVoice/Features/Home/ScreenshotHandoff.swift` — iOS 전용, NSUserActivity 발행/정리 (신규)
- `ArcaVoice/Features/Home/HomeView.swift` — 스크린샷 감지 시 탭 없이 자동 분석 + Handoff 발행 + 인앱 "일정 만들기" 버튼
- `ArcaVoice/Features/Notch/NotchAgent.swift` — `.handoffReview`/`.creatingSchedule` 모드, `presentHandoffReview`/`confirmHandoffSchedule`/`dismissHandoffReview`/`openHandoffSession`
- `ArcaVoice/Features/Notch/NotchView.swift` — 위 모드 렌더링 (기존 `promptRow` 재사용)
- `ArcaVoice/App/RootView.swift` — macOS `onContinueUserActivity` 핸들러
- `project.yml` — `NSUserActivityTypes`에 activity type 등록 (iOS/macOS 같은 타겟이라 한 번만 추가하면 됨)

## 한계 / 확인 필요

- Handoff는 **같은 Apple ID + 블루투스/와이파이 켜짐 + 두 기기 모두 근접**해야 뜬다 — 시스템 설정(Handoff 켜짐)은 사용자 쪽에서 이미 켜져 있다고 가정.
- `NSUserActivity`는 스크린샷 감지 시점에 ARCA 앱이 **foreground**여야 발행된다 (iOS가 백그라운드 앱에는 스크린샷 알림을 안 준다) — 인앱 브라우저(BrowserAgent)로 뭔가 보다가 스크린샷 찍는 흐름을 우선 상정.
- 세션 동기화가 GitHub 릴레이 왕복(몇 초)에 걸리므로, Handoff 아이콘을 클릭한 직후 아주 짧은 로딩이 있을 수 있다 — 6회(약 12초) 안에 못 찾으면 알림으로 안내.
- 실제 두 기기 간 Handoff 동작은 시뮬레이터/샌드박스에서 검증 불가 — 실기기 페어(아이폰+맥)로 빌드해서 확인 필요.
