# Spec — ARCA 투자 내러티브 덱 (ZER01NE Sprint IR Day 2026-09-21 · 10분 + Q&A 20분)

> **정정 (2026-09-10 밤):** 피칭 9/21 10:20, 발표 **10분**, IR 자료 제출 **9/17 15:00**(임유미). §2.2의 15분/13장은 **10분/11장**으로 압축 — S8+S9 병합, S12는 S13에 흡수. 산출물 형식 = 단일 HTML 웹 덱(`ir/arca-fund3/index.html`, thezonebio.com/arcapitch) + 9/17 PDF 출력. 멘토(김정수) 3차 메모의 스토리라인(페르소나=대표 본인, AS-WAS→AS-IS, 내 얘기→주변 10명→커뮤니티, 도그푸딩 영상 1개)과 정합. 플랜: `docs/superpowers/plans/2026-09-10-fund3-deck.md`.

Source of truth: `intent/arca-zer01ne-fund3-narrative.intent.md` (판결 A~F 승인, 열린 질문 8개 전부 해소 — §0). 작성 2026-09-10.

## 0. 인텐트 열린 질문 → 해소 결과

| # | 질문 | 해소 (민성, 2026-09-10) |
|---|---|---|
| 1 | 돈 있어도 못 붙이는 것 | **해자 논증 채택** (§2.1). 하드웨어는 해자가 아니라 비대칭 1의 입력면으로 포함 |
| 2 | knot 수상명 | **Google Cloud × Solana AI Agentic Hackathon 3위** (2026-08-21 데모데이) |
| 3 | Ask | **5억, 프리시드, 12개월** |
| 4 | 데모 장면 | **3장면 원플로우**: 회의 녹음 → 기억 반영 → 사람별 맥락으로 답장 초안 → 승인 발송 |
| 5 | 9/19 목표 | 설치 30 / 주간활성 15 / 닫힌 루프 100+ / 유료 10 **+ 사용자별 승인율·자동실행 비율 일별 곡선** |
| 6 | "에이전트가 쓰는 옵시디언" | STT 보정 맞음. 데이터를 가두지 않음 → 그래서 다 보여준다 = 비대칭 1의 신뢰 근거 |
| 7 | Friend와의 차이 | "Friend는 떠들 뿐 해주는 일이 없었다. ARCA의 애정은 대화가 아니라 일에서 온다" |
| 8 | 팀 | 6월 덱 그대로 **박민성·박진성(HW)·하승호(임베디드) 3인** |

추가 요구(민성): 덱을 **Sequoia 프레임 + gstack CEO-review 렌즈 + 심사역 시뮬레이션**으로 검증해 "투자할 수밖에 없게" 만든다 (§5).

---

## 1. Requirements

R-번호 → 인텐트 근거 (AC = 인텐트 §5 acceptance criteria).

### 내러티브
- **R1** 첫 장 한 문장 = "ARCA는 공수 0으로 당신의 하루를 기억하고, 그 기억으로 대신 일을 끝내는, 함께 커가는 컴패니언이다." 변형은 허용, 세 요소(공수 0 기억 / 대신 끝냄 / 함께 커감)는 필수. → AC-1
- **R2** 인텐트 §3.2의 1·2·3·6번이 **사용자 시점 문장**으로 슬라이드에 존재 ("이제 유료 회의록 앱이 필요 없다", "일기를 대신 써준다", "누구와 어디까지 얘기했는지 기억한다", "덜 중요한 잔일을 먼저 찾아 물어본다"). → AC-2
- **R3** 해자 슬라이드 1장 = 비대칭 3 + 복리 루프 (§2.1). Q&A 카드에 "OpenAI가 메모리 잘하면?" 30초 답. → AC-3
- **R4** 금지어 0건: `비타민`, `second self`, `Second Self`, `방패`, `flow-state guardian`, `second brain`(부정 맥락 제외). → AC-4, 판결 A·B·D
- **R5** "왜 현대"는 **Why-now 슬라이드에 흡수**되어 별도 슬라이드 없음 (H Chat Pro 3만 명 = "묻는 AI는 깔렸다"의 증거로만). → AC-10, 판결 E

### 트랙션
- **R6** 트랙션 숫자 전부 `usage_events` 집계에서 생성, 라이브 대시보드로 발표 중 재현. → AC-5
- **R7** 표기 = 9/10 기준값 → 9/19 값 델타. → AC-6
- **R8** 사용자별 **위임 승인율 · 자동실행 비율의 일별 곡선** 1장 (해자 논증의 측정 증거). → §0-5
- **R9** 유료/유료파일럿 증거 ≥1 스크린샷, 없으면 "시도·막힌 이유" 슬라이드. → AC-7
- **R10** 첫 사용자 주장에 행동 증거 ≥1 (먼저 연락해 온 창업자 수, 재사용 코호트). → AC-8

### 팀·구조
- **R11** 팀 슬라이드 사실: 3인 구성, knot 3위, `git log --since=2026-06-01` 커밋/활동일(발표 전 재집계), ISEF 2등·Caltech(하승호), 서울대 기계+심리설계(박진성). 전부 출처 확인. → AC-9
- **R12** 하드웨어 자금 ≤ 15%; 트윈·SNS·인증체계 한 줄 이하; 밸류 미기재; SOC 2·ISMS-P는 로드맵 표기. → AC-11, 판결 F
- **R13** Ask 슬라이드: 5억 / 12개월 / 사용처 / 90일 성공 기준. → §0-3
- **R14** 산출물 4종: 슬라이드 스펙, 낭독 스크립트(15분), 1페이지 요약, Q&A 카드. → AC-13
- **R15** 리허설 3회 타임로그, 90초 폴백 영상, 오프라인 데모 경로. → AC-12

### 정렬
- **R16** 랜딩·README·DESIGN·PRD·canon 헤드라인이 R1과 같은 말을 한다. → AC-1, 인텐트 §4 제약

### 비기능
- **N1** 모든 외부 숫자에 1차 출처 각주 (인텐트 §4)
- **N2** 슬라이드 파일은 6월 덱 포맷(`deck/arca-hyundai-15min-slides-KR.md`)과 같은 구조: 제목 / 화면 내용 / 데이터 콜아웃 / 비주얼 / 출처 / 낭독 매핑
- **N3** 계측 코드는 새 테이블·새 인증 없이 기존 `usage_events` + `x-arca-token` 재사용 (ponytail)

---

## 2. Design

### 2.1 해자 논증 (덱의 심장, 채택본)

전제: 메모리 가치 = 입력면 × 행동 권한 × 시간. "메모리 있다"는 해자가 아니다.

1. **비대칭 1 — 입력면: 클수록 덜 보여준다.** 플랫폼 기업의 상시 기록은 사회적 계약 위반(Microsoft Recall 회수, 2024 — 발표 전 날짜·출처 재확인)이고 보수 조직엔 보안 사고다. 사용자가 고른 작은 컴패니언이 **사용자 소유 저장소(에이전트가 써주는 나의 위키)**에 쓰는 것만 하루 전체를 볼 허락을 받는다. 하드웨어(ARCA Core)는 대면·오프라인 대화까지 입력면을 넓힌다. ARCA가 더 보는 이유 = 모델이 아니라 **사용자가 들여보내주기 때문**. 데이터를 가두지 않기 때문에 다 보여준다.
2. **비대칭 2 — 완수 데이터: 보는 것과 행동하는 것이 한 몸일 때만 생긴다.** 회의록 앱은 보지만 행동 안 함, 스위트 어시스턴트는 행동하지만 스위트 안만 봄. 둘을 동시에 하는 에이전트만 "무엇을 맡겼고 승인했고 거절했나" 로그를 쌓는다. 이 로그가 위임 상한을 안전하게 올리는 유일한 자산; 사람마다 다르고, 행동해야만 생기고, 살 수도 옮길 수도 없다.
3. **비대칭 3 — 관계: 복리가 느껴져야 캡처가 켜져 있다.** "함께한 N일", "오늘 너에 대해 이걸 배웠어". 생산성 브랜드는 귀여울 수 없고 컴패니언 앱은 일을 못 한다. Friend와의 차이: 애정은 대화가 아니라 **일**에서 온다.
4. **복리 루프** (슬라이드 비주얼): 하루가 들어온다 → 맥락 → 제안↑ → 승인↑ → 안전한 위임 범위↑ → 되찾은 시간↑ → 애정↑ → 더 들여보낸다.
5. **측정**: 사용자별 승인율·자동실행 비율이 일수에 따라 우상향하면 논증 증명 = R8.

### 2.2 슬라이드 아키텍처 (15분, 13장 + 부록) — Sequoia 매핑

| # | 슬라이드 | Sequoia 요소 | 시간 | 재사용 |
|---|---|---|---|---|
| S1 | 타이틀 + 한 문장 (R1) | Company purpose | 0:20 | — |
| S2 | 나는 병목이 됐다 | Problem | 0:50 | 6월 S2·S3 |
| S3 | 사용자 0번의 하루 — 되돌아가기 싫은 4가지 (R2) | Solution | 1:00 | 신규, 인텐트 §3.2 |
| S4 | **라이브 데모 3장면 원플로우** | Product | 5:00 | 신규 |
| S5 | 왜 지금 — 모두가 메모리를 만든다 + 묻는 AI는 깔렸다(H Chat Pro 3만/80%) (R5) | Why now | 0:50 | 전략문서 §1 |
| S6 | **해자 — 비대칭 3 + 복리 루프** (R3) | Competition | 1:30 | §2.1 |
| S7 | **트랙션 — 9일 델타 + 승인율 곡선** (R6·7·8·9·10), 라이브 대시보드 | Traction | 1:30 | 신규 |
| S8 | 첫 사용자 → 확장 경로 + TAM 1출처(GVR $8.46B→$35.7B) | Market / GTM | 0:40 | 6월 S11 |
| S9 | 비즈니스 모델 — ₩12,900/₩19,900, GM 63%, 붕괴점 월 30h | Business model | 0:40 | 6월 S12·부록C |
| S10 | 팀 3인 + knot 3위 + 커밋/활동일 (R11) | Team | 0:50 | 6월 S14 갱신 |
| S11 | Ask 5억/12개월 + 사용처 + 90일 기준 (R13) | Financials / Ask | 0:50 | 전략문서 §5 (하드웨어 ≤15%) |
| S12 | 비전 한 장 — 사다리, "1층이 안 되면 무의미" | Vision | 0:30 | ARCA-VISION §1 |
| S13 | CLOSE "arca 해놔" + 던지는 질문 1개 | — | 0:30 | 6월 S18 |
| 부록 | A 보안 3-tier(PRD §9.5) · B 경쟁 매트릭스(6월 S9) · C 유닛이코노믹스 원자료 · D Q&A 카드 · E 1페이지 요약 | | | |

합계 ≈ 14:00 + Q&A 여유.

### 2.3 데모 3장면 원플로우 (S4) — 코드 경로

| 장면 | 사용자가 보는 것 | 뒤에서 도는 것 |
|---|---|---|
| ① 기록 | 실제 짧은 회의(또는 ARCA Core 실물로 녹음) → 요약·결정·액션아이템 카드 (9/10 스크린샷 화면) | `FinalPassRunner` → 요약 → `BrainClient.remember` (회의→기억 추출, `arca-brain-server-2026-09-08`) |
| ② 기억 | Brain에 "○○님과 ○○ 건, 어디까지" 페이지가 생김 / 노치 챗에서 "○○님이랑 마지막에 뭐 얘기했지?" 리콜 | `/api/brain/context`, `MemoryPrompt.systemBlock(facts:brain:)` |
| ③ 위임 | 그 사람에게 답장 초안이 사람별 맥락으로 제안 → "대신 해줄까?" → 승인 → 실제 발송 → 노치 셀레브레이션 | `AmbientOps` ReplyProposal → `approve()` (`apps/arca/ArcaVoice/Features/Ops/AmbientOps.swift:286`) → Composio Gmail/Slack |

폴백: 90초 영상(같은 3장면). 오프라인: 테더링 + 사전 녹음된 회의 파일로 ①만 로컬 재현.

### 2.4 트랙션 계측 — 기존 인프라 재사용 (N3)

**있는 것**
- `lib/db/schema.ts:72` `usage_events` (device_id / user_id / organization_id / `kind` enum / ok / at, 인덱스 있음)
- `lib/arca/usage.ts` `record()` — 이미 쓰는 쓰기 함수
- `lib/arca/digest.ts` — `usage_events` 집계 SQL 패턴(주간 다이제스트)
- `BrainClient` (`apps/arca/Packages/ArcaVoiceKit/Sources/ArcaVoiceCore/BrainClient.swift`) — `x-arca-token` 인증, `request(path, method)`, `remember/refreshContext/consolidateNow` 패턴

**바꾸는 것 (최소)**
1. `usageKindEnum`에 kind 추가: `app_open`, `meeting_captured`, `proposal_shown`, `proposal_approved`, `proposal_rejected`, `task_tossed`, `loop_closed`. → drizzle 마이그레이션 `0004_*` (enum ALTER ADD VALUE).
2. `POST /api/brain/events` — 배치 `{events:[{kind, at, ok}]}`, 인증·스코프는 `/api/brain/remember`와 동일(`lib/brain/owner.ts`), 내부에서 `record()` 호출. 새 인증 없음.
3. `GET /api/brain/metrics` — 같은 토큰, 반환: `{users, installs, wau, closedLoops, byDay:[{day, proposals, approved, autoExecuted, approvalRate}], retention:{d1,d3,d7}, since}`. 집계 SQL은 `digest.ts` 패턴 복제.
4. `app/arca/metrics/page.tsx` — 토큰 게이트, 숫자 4개 + 승인율 라인차트 1개. 발표용. (스타일: `DESIGN.md` 토큰)
5. Swift `BrainClient.track(_ kind: String, ok: Bool = true)` — 로컬 큐 + 배치 플러시(오프라인 허용). 호출 지점:
   - `AppServices` 런치 → `app_open`
   - `FinalPassRunner` 회의 완료 → `meeting_captured`
   - `AmbientOps` 제안 생성 → `proposal_shown`; `approve()` 성공 → `proposal_approved` + `loop_closed`; 제안 삭제/무시 경로 → `proposal_rejected` (경로는 플랜 단계에서 `ReplyProposal` 상태 전이 grep으로 확정)
   - `TaskEngine.toss()` 완료(`state = .done`) → `task_tossed` + `loop_closed`; 자동 toss(AutonomyLevel ≥ sendRoutine)면 `auto_executed` 플래그는 `model` 컬럼 대신 kind `auto_executed` 추가 이벤트로
6. 테스트: `lib/brain/logic.test.ts` 옆에 metrics 집계 순수함수 테스트(`npm run test:brain`에 포함), Swift `BrainClientTests`에 track 페이로드 1개.

**주의**: 다른 세션(arca-d3)이 `arca-cloud-swift` 브랜치(34파일)를 main에 머지 중 → Swift 계측은 **그 머지가 main에 오른 뒤** 시작. 서버 측(1~4)은 즉시 가능.

### 2.5 정렬 편집 (R16)

| 파일:행 | 현재 | 변경 |
|---|---|---|
| `README.md:1` | "your independent second brain" | R1 문장 영어판 |
| `README.md:17,28,152` | second brain 용어 | "memory" 로 |
| `DESIGN.md:15` | "second brain hub" | "memory + delegation companion" |
| `app/arca/page.tsx:506` | "YOUR SECOND SELF · AGI COMPANION OS" | R1 영어 헤드라인 |
| `app/arca/page.tsx:373,393,814` | "second self" 롤·티어명·CTA | 티어명 "Second Self" → "Companion Pro"(가격 유지), CTA 문구 교체 |
| `docs/ARCA-PRD.md` 히어로 정의 | flow-state guardian | 판결 A 반영 + 개정 이력 1줄 |
| `~/MY ZONE/ME/THE ZONE/Brand/ARCA-WORLDVIEW-CANON.md` (리포 밖, locked) | 방패 히어로, second brain·friend 거부 | 판결 A·B·C를 "개정 2026-09-10" 섹션으로 추가 — 기존 텍스트 삭제 대신 판결 병기 |
| `docs/ARCA-VISION.md §8-4, §7` | "방패로 통일", "애착은 물건" | 판결 A·C로 갱신 |

랜딩 카피 변경은 **D-2(9/17) 이후**에 배포 — 스프린트 중 베타 유저 혼란 방지 (§6).

### 2.6 산출물 파일 (R14)

- `deck/arca-zer01ne-fund3-slides-KR.md` — 슬라이드 스펙 (N2 포맷, 출처 각주)
- `deck/arca-zer01ne-fund3-spoken-KR.md` — 낭독 15분 (S4 데모 콜아웃 포함)
- `deck/arca-zer01ne-fund3-onepager-KR.md` — 심사역 1페이지 (문제·제품·왜 지금·해자·트랙션·팀·Ask)
- `deck/arca-zer01ne-fund3-qa-KR.md` — Q&A 카드 (전략문서 §7 + 해자 반격 2개 + 팀 풀타임 질문)
- 렌더: 6월과 동일하게 마크다운 마스터 → 발표 파일(Keynote/HTML). 포맷은 플랜에서 결정 (`ir/arca-pitch.html` 패턴 재사용 가능).

---

## 3. Guidelines applied

- 프로젝트 `CLAUDE.md`, `docs/BRAND.md` **없음**. 시각 토큰은 `DESIGN.md`(라운드 오렌지 스피릿, 엠버 팔레트) 따름.
- 메모리 `arca-verb-positioning`: ARCA를 명사로 설명하지 말고 동사·세계관으로 — S1·S13 "arca 해놔" 유지. **단** 판결 B로 "기억"은 헤드라인 가치로 허용.
- 메모리 `no-codex-for-arca`: 설계·UX는 Claude 직접; 계측(§2.4)은 신기능이라 **ARCA Test 앱에서 선검증** 후 메인.
- 6월 덱 원칙 유지: 슬라이드 빽빽·낭독 lean, 숫자 1차 출처, 보유하지 않은 것 주장 금지.
- `deck/arca-yc-investor-gap-audit-KR.md` CONFIRMED/ASSUMED 표 재사용, 재논쟁 금지.
- **충돌 명시**: locked canon("충돌하면 이 문서가 이긴다")을 이 스펙이 개정한다. 개정은 삭제가 아니라 "판결 병기"로 — 원문 보존.

---

## 4. Out of scope

인텐트 §4에서 승계: 트윈·SNS·인증체계(한 줄 이하), 10/13 파이널 덱, 기능 나열, 깊은 재무 모델, 하드웨어 CAD/BOM/인증.

이 스펙에서 추가 제외:
- 결제 인프라(Stripe/토스) 구축 — 계좌이체+수동 인보이스로 우회 (전략문서 §4)
- 멀티유저 대시보드/어드민 — 발표용 단일 페이지만
- 승인율 곡선의 통계적 유의성 — N이 작다고 정직하게 표기, 사용자별 선으로 보임
- 영어판 덱
- 제로원 협업 프로젝트 제안서(전략문서 S11) — 판결 E로 제외; 심사역이 요청 시 별도

---

## 5. Verification

| 요구 | 방법 | 결정론적? |
|---|---|---|
| R1·R16 | `grep -rn` 으로 R1 세 요소 키워드가 첫 장·README:1·page.tsx 히어로에 존재 확인 | ✅ |
| R4 | `grep -rniE '비타민|second self|방패|flow-state guardian' deck/arca-zer01ne-fund3-*.md app/arca/page.tsx README.md` → 0줄 | ✅ |
| R2·R3·R5·R12·R13 | 슬라이드 스펙 파일 내 체크리스트 표(Sequoia 13요소 × 슬라이드 번호) 전부 채워짐; 하드웨어 % ≤ 15 | ✅ (표 검사) |
| R6·R7·R8 | `curl -H x-arca-token GET /api/brain/metrics` 가 스키마대로 응답; `npm run test:brain` 그린(집계 함수 테스트 포함); 대시보드 스크린샷 1장; 슬라이드 숫자 = API 응답값 | ✅ |
| Swift 계측 | `xcodebuild … -scheme ARCA` 그린 + BrainClientTests 그린 + ARCA Test 앱에서 승인 1회 → DB에 `proposal_approved` 행 확인 | ✅ |
| R9·R10 | 스크린샷 파일 존재 (`deck/images/fund3/`), 없으면 "막힌 이유" 슬라이드 존재 | ✅ |
| R11 | 팀 사실 각 항목에 출처 링크/파일 각주; 커밋 수는 발표 전날 `git log --since=2026-06-01 --oneline | wc -l` 재집계 | ✅ |
| R14 | 파일 4개 존재 + 1페이지가 A4 1장 이내(PDF 렌더) | ✅ |
| R15 | 리허설 타임로그 3행(`deck/arca-zer01ne-fund3-rehearsal.log`), 폴백 mp4 존재 | ✅ |
| **렌즈 A — Sequoia** | 13요소 커버리지 표 (§2.2) 빈칸 0 | ✅ |
| **렌즈 B — gstack** | `git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && ./setup` 후 `/plan-ceo-review` 를 슬라이드 스펙에 실행 → 지적 사항 전부 "수용/거부+이유"로 기록 | 판단 필요 |
| **렌즈 C — 심사역 시뮬레이션** | 프레시 컨텍스트 리뷰어 2명(① 제로원 3호펀드 CVC 심사역 페르소나: 그룹 시너지·리스크 중심 ② 일반 시드 VC: 왜 지금 이 팀에 돈을 넣나) 에게 덱+1페이저만 주고 "투자하지 않는 이유"를 심각도별로 받음 → high 0건까지 반복 (최대 3라운드) | 판단 필요 |
| **렌즈 D — 민성 리허설 Q&A** | Q&A 카드의 모든 질문에 30초 내 답 — 타임로그 | 판단 필요 |

---

## 6. Risks / interrogation — "여기서 뭐가 깨질 수 있나"

| 리스크 | 왜 진짜인가 | 완화 |
|---|---|---|
| **9일에 계측+유저+덱 셋 다** — 민성 1인의 시간이 병목 | 계측은 코드, 유저는 콜, 덱은 글. 전부 같은 사람 | 계측 서버 측은 D-9 하루로 끝냄(§2.4 1~4는 반나절 분량); Swift는 arca-d3 머지 후 반나절; 유저 콜은 D-7~D-3에 몰기; 덱 초안은 계측과 병행해 Claude가 씀 |
| **승인율 곡선이 평평하거나 노이즈** — N 작음, 9일 | 해자 논증의 "증거"가 반증처럼 보일 수 있음 | 사용자별 선으로 그리고, 사용자 0번(민성, 42일치)의 곡선을 앵커로. 평평하면 "9일은 짧다, 90일 기준으로 건다"로 정직 표기 |
| **arca-d3 머지와 Swift 계측 충돌** | 34파일 충돌 머지 진행 중, `AppServices`·`AmbientOps` 겹칠 가능성 | Swift 계측은 머지 후 시작; arca-d3에 계측 파일 목록 사전 공유 (SendMessage) |
| **랜딩 카피 변경이 베타 유저를 혼란** | 스프린트 중 온보딩 중인 사람이 "Second Self" 보고 들어옴 | 랜딩·README 정렬은 D-2 이후 배포; 덱과 랜딩 불일치 구간은 9/17~9/19 사이 0 |
| **locked canon 개정** — "충돌하면 이 문서가 이긴다"를 이 스펙이 뒤집음 | 다른 세션·에이전트가 canon 기준으로 카피를 되돌릴 수 있음 | canon에 개정 섹션 추가(원문 보존) + 메모리 `arca-vision-canon-conflict`·`arca-prd-v1`·`arca-verb-positioning` 갱신 |
| **라이브 데모 3장면은 실패 지점 3배** | Composio Gmail 발송, 서버 왕복, 실회의 녹음 전부 네트워크 의존 | 90초 폴백 영상 필수; 오프라인 경로는 ①만; 리허설 3회 중 1회는 네트워크 끊고 |
| **Recall·H Chat 숫자가 언론 인용** | 1차 출처 아님 → 심사역이 반박하면 신뢰 사고 | 발표 전 각 숫자 1차 출처(현대차그룹 뉴스룸, Microsoft 공지) 링크로 교체, 못 찾으면 삭제 |
| **팀 3인의 실제 관여도 질문** | "풀타임 누구냐"에 민성이 아직 답을 정하지 않음 | Q&A 카드에 정직한 답 사전 작성 (민성 확정 필요 — 플랜의 첫 체크포인트) |
| **하드웨어를 입력면으로 넣으면 "또 하드웨어냐"** | 6월 피드백이 좁히기였음 | S6에서 한 절만, S11 자금 ≤15%, "SW로 리텐션 증명 후 확대" 문장 고정 |
| **"모두가 만든다"를 우리가 먼저 인정** | 심사역이 "그럼 왜 너냐"를 더 세게 물음 | 그게 의도 — 비대칭 1·2가 그 질문의 답. 인정 없이 가면 순진해 보임 |

---

## 7. Hand-off

다음 단계: Superpowers `writing-plans` → `plan.md`. 플랜의 첫 체크포인트 = 팀 풀타임 답 확정(민성) + arca-d3 머지 상태 확인. 워크트리: 이 문서들은 `arca-wt-brain`(main)에 있으므로, 계측 코드는 브랜치 `fund3-metrics`로.
