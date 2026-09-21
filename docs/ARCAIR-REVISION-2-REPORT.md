# ARCAIR 리비전 2 리포트 — 2026-09-21 (Claude Fable 5.1)

브리프: `docs/ARCAIR-REVISION-2-BRIEF.md`. 전 단계: `docs/ARCAIR-OVERNIGHT-REPORT.md`.

## 한 줄 요약

덱은 카피·발표자 노트 전면 재작성 + "ARCA it?" 핵심 장면을 발표자가 → 키로 넘기는 2장(8·9)으로 분리해 **thezonebio.com/arcair에 v4.1로 라이브**. `/arca` 랜딩 복원 PR #11은 스크린샷 재검증 후 **main 머지·프로덕션 반영**(thezonebio.com/arca). arcair-ver1은 바이트 단위로 불변 확인.

## 1. 링크

| 항목 | 링크 | 상태 |
|---|---|---|
| arca PR #11 (/arca 랜딩 복원 + 덱 v4.1) | https://github.com/METHEZONE/arca/pull/11 | **MERGED** 02:05 UTC (11:05 KST) |
| thezonebio.com PR #7 (/arcair ← v4.1, v4 스냅샷) | https://github.com/METHEZONE/thezonebio.com/pull/7 | **MERGED** 02:05 UTC |
| 라이브 덱 | https://thezonebio.com/arcair | 20장 · 562,922B · `ir/arcair/index.html`(arca `5e928e6`)과 `cmp` 동일 · JS 에러 0 |
| 라이브 랜딩 | https://thezonebio.com/arca (→ `arca-the-zone-bio.vercel.app/arca` 프록시) | Spirit 히어로 · MILO/PIXEL/VOX/SILO · 웹앱 CTA `/arca/onboarding` 확인 |
| ver1 | https://thezonebio.com/arcair-ver1 | `ir/arcair-ver1/index.html`과 바이트 동일, 미변경 |
| 롤백 | thezonebio.com 저장소 `cp public/arcair-v4-backup-20260921/index.html public/arcair/index.html` | v3 백업도 `public/arcair-v3-backup-20260921/` 그대로 |

덱 정본은 arca 저장소 `ir/arcair/index.html`, 사본 `public/arcair/index.html`(Vercel 프리뷰용). 배포 커밋: arca `5e928e6`, thezonebio.com `arcair-v4-1-revision` 브랜치 2커밋(스냅샷 → 교체).

## 2. 무엇을 바꿨나

### 2-1. 카피 전면 재작성 (19장 본문 + 발표자 노트 전부)

기준: 소리 내어 읽었을 때 발표하다 튀어나온 말 같을 것. "~합니다" 벽, 대칭 3단, 뻔한 접속사 제거. 숫자·계약 금액·5억 SAFE·S5 ★ 두 문단은 의미 불변(★ 문단은 문장도 거의 그대로 둠 — 브리프가 "의미 왜곡 금지"로 못 박은 문단이라 어미만 손댔다).

변경 전/후 예시:

| 장 | 전 (v4) | 후 (v4.1) |
|---|---|---|
| 커버 | AI한테 일 시키는 건 이제 누구나 해요. 그 일, 끝까지 누가 봐요? | 오늘 AI한테 일 하나쯤 시켜보셨죠. 그 일, **지금 어디까지 갔는지** 아세요? |
| S2 | AI가 실행 비용은 낮췼는데, 새 비용을 만들었어요. / 문제는 AI 능력이 아니라, 사람이 오케스트레이션하는 방식. | 실행은 싸졌어요. 대신 새 청구서가 왔죠. / 모델 성능 문제가 아니에요. **사람이 main thread인 게 문제.** |
| S3 | 생산성 문제가 아니라 신뢰 문제였어요. / 이 미래를 먼저 살다가 문제를 밟은 사람. | 생산성 문제인 줄 알았는데, 신뢰 문제였어요. / 이 미래를 먼저 살다가 **발을 헛디딘 사람.** |
| S4-3 | 자율 실행이 늘면 관리 부담도 같이 는다. 지금 구조에선 그게 기본값. | 자율 실행이 늘면 관리도 같이 늘어요. 지금 구조에선 그게 기본값. **해방이 아니라 승진이죠. 관리자로.** |
| S7 | 그래서 안정적으로 가능합니다. | 그래서 안정적이에요. **재미없게 들리긴 하지만.** |
| S9 | 같은 문제에, 기업도 돈을 냅니다. | 같은 문제에, **회사도 지갑을 열었어요.** |
| S15 | ARCA MOMENT · 명령을 기다리지 않는 AI | ARCA MOMENT · **AI가 먼저 묻는다** |

발표자 노트도 같은 톤으로 다시 썼고, 8·9장 노트에는 → 타이밍 `(→)`을 박아 넣었다 (N 키로 확인).

### 2-2. 핵심 장면 강화 — 1장 13초 자동 재생 → 2장, 발표자 페이스

진단: v4의 8장은 "ARCA it?" 제안 토스트가 3.2초에 떠서 **8.6초에 사라졌다**. 발표자가 말하는 동안 핵심 대사가 화면에서 없어지는 구조. 520px 토스트라 크기도 작았다. Min이 "지나가듯 보이면 안 된다"고 다시 강조한 이유가 이거라고 판단.

해결: 슬라이드 안 단계(fragment). → 키/클릭/스와이프가 다음 단계를 켜고, 단계가 다 켜지면 다음 장으로. ← 는 단계를 되감는다. 우하단 nav에 `1/2 →`로 남은 단계 표시. `?print=1`과 스크린샷 스크립트는 전 단계 펼침.

| 장 | 단계 | 화면 |
|---|---|---|
| **8 · "시킨 적 없어요. ARCA가 먼저 물어요."** | 0 (자동) | Mac 화면에 OEM 미팅 전사가 실시간으로 흐름. "금요일까지 견적서 보내드릴게요" 하이라이트. 칩: 약속 감지 1 · 판단 지점 1(단가) · 사람 이팀장·OEM · 분위기 우호적(웃음). "녹음 앱·전사 앱·메모 앱, 따로 없음. 그냥 대화." |
| | 1 (→) | **스포트라이트.** 화면이 어두워지고 800px 카드가 팝 + 주황 링 펄스. "ARCA · 미팅 끝나기 3분 전 · **시킨 사람 없음**" / "**ARCA it?** 「금요일까지 견적서, 300개 기준」 잡았어요. 여기부터 여기까지 제가 할게요. 초안 쓰고, 승인받고, 보내고, **이팀장 회신까지 확인해서** 보고드릴게요. **맡기실래요?**" 발표자가 넘기기 전까지 그대로 머문다. |
| | 2 (→) | "그래, 맡길게 ✓" 눌림 → Commitment Graph가 그려지고 커서가 드래그로 범위를 긋는다. 라벨 "「여기부터 여기까지」 · 드래그로 그은 만큼만 ARCA 몫". |
| **9 · "막히면 멈추고, 끝나도 먼저 되물어요."** | 0 (자동) | 월요일 09:12. 경계 정지 토스트: "초안 다 썼는데요, 이팀장이 '단가 좀 봐달라'고 했잖아요. **가격은 제 범위 밖**이에요. 5% 이내로 맞춰서 갈까요, 그대로 갈까요?" → "5% 이내 OK" 눌림. 캡션 "이게 이번 건의 유일한 개입." |
| | 1 (→) | 외부 증거 토스트(녹색): "회신 도착 · 견적 수락. '보냈어요'는 ARCA 말이고, '수락'은 이팀장 말이에요. 후자만 끝. node 잠금." 그래프 나머지 노드 점등, 마지막 노드 녹색 잠금. |
| | 2 (→) | **두 번째 스포트라이트.** "ARCA · 먼저 되묻기 · **이것도 시킨 사람 없음**" / "끝났어요. 그런데 다음 견적 메일은 톤을 더 맞추고 싶어요. **마음에 들었던 메일 하나만** 던져주실래요? **그거 레퍼런스로 삼을게요.**" |

구현은 CSS 두 줄 + JS 두 함수: `.frag{visibility:hidden}` / `section.s.active .frag:not(.on) *{animation:none}` (켜지는 순간 그 단계 안 `--d` 딜레이가 0부터 시작) / `.frag.on:has(+.frag.on)`으로 이전 스포트라이트 숨김. 자동 재생 타이밍표 대신 발표자 리듬을 따른다.

### 2-3. /arca 랜딩 PR #11 재검증 → 머지

로컬 `npm run dev` 1440/375에서 재촬영. IntersectionObserver 리빌 때문에 스크롤 없이 풀페이지 캡처하면 빈 화면이 나오는데(첫 시도에서 확인), 스크롤 스캔 후 캡처하니 전부 살아 있음: Spirit 히어로(커서 추적 눈), 스크롤 라이더, `arca it —` 타이핑, 위임 데모 창, ARCA/MILO/PIXEL/VOX/SILO/YOURS 카드, 프라이싱, 베타, 웨이트리스트. 가로 overflow 0, JS 에러 0. Vercel 체크 SUCCESS 확인 후 draft 해제 → main 머지 커밋으로 머지. thezonebio.com/arca는 `next.config.ts` beforeFiles rewrite로 arca Vercel 프로젝트를 프록시하므로 별도 배포 없이 반영됐고, 라이브 HTML에서 MILO/`/arca/onboarding` grep으로 확인.

### 2-4. 배포 (thezonebio.com)

1. `public/arcair-v4-backup-20260921/index.html` ← 라이브 v4 스냅샷 (파일만, 라우팅 없음)
2. `public/arcair/index.html` ← v4.1 (`cmp` 동일)
3. PR #7 → Vercel SUCCESS → main 머지 → 약 2분 뒤 프로덕션에서 562,922B `cmp` 동일 확인.

## 3. 검증

| 항목 | 결과 |
|---|---|
| 덱 렌더 (Chrome headless 1920×1080) | 20/20 장 요소 overflow 0, JS 에러 0. 8·9장은 단계별(0/1/2) 별도 촬영 |
| `npm run lint` / `npm run typecheck` | 통과 (덱은 정적 HTML이라 영향 없음, 랜딩 코드 확인용) |
| 라이브 덱 | `thezonebio.com/arcair` 200 · 정본과 바이트 동일 · 20 섹션 · JS 에러 0 |
| 라이브 랜딩 | Spirit 마커·CTA grep 확인 + 스크린샷 |
| ver1 | `thezonebio.com/arcair-ver1` ↔ `ir/arcair-ver1/index.html` `cmp` 동일 |

## 4. 스크린샷

- 덱 전체: `docs/screenshots/arcair/01.png` ~ `20.png` (전 단계 펼침 상태)
- 핵심 장면 단계별: `docs/screenshots/arcair/08-step0.png`, `08-step1.png`, `08-step2.png`, `09-step0.png`, `09-step1.png`, `09-step2.png`
- 랜딩(로컬): `docs/screenshots/landing/desktop-1440-hero.png`, `desktop-1440-demo.png`, `desktop-1440-agents.png`, `desktop-1440-full.png`, `mobile-375-full.png`
- 라이브(thezonebio.com): `docs/screenshots/live/thezonebio-arcair-v41-01.png`, `-08-step1.png`, `-09-step2.png`, `-20.png`, `thezonebio-arca-hero.png`, `thezonebio-arca-agents.png`

## 5. 내가 내린 판단 (근거)

- **자동 재생 → 단계 진행.** "지나가듯 보이면 안 된다"는 요구에 타이밍을 늘리는 건 반쪽 답. 발표자가 말을 끝낼 때까지 카드가 머무는 게 맞다고 봤다. 대신 각 단계 안에서는 기존 모션 그대로 자동 재생.
- **1장 → 2장 분리.** 제안(먼저 묻기)과 되묻기(경계 정지·증거·레퍼런스)를 한 화면에 넣으면 둘 다 작아진다. Min이 "제안"과 "능동적으로 되묻기" 둘을 따로 짚었으니 각각 스포트라이트를 받게 했다. 20장이 됐다.
- **★ S5 문단은 거의 그대로.** 브리프 3항 "파괴적 재작성 허용"과 2항 "의미 왜곡 금지"가 이 문단에서 충돌하는데, 후자를 택했다. 카드 제목만 "우리가 진짜로 만드는 것"으로.
- **arcair-ver1 미접촉**, v4 스냅샷 보존, v3 스냅샷도 그대로.
- **PR #11 머지 방식은 merge commit.** 저장소 최근 이력(`1e7a888 Merge pull request #9`)과 동일.

## 6. 막힌 것 / 남긴 것

- **커버 슬라이드 톤이 무거운 편.** 사진·비주얼 없이 텍스트+Spirit만인 건 v4와 같다. Min이 "이전 arcair 느낌"에서 커버 비주얼을 원하면 ver1 커버(사진 배경) 재활용 가능.
- **"+50% / 2×" 출처**는 v3부터 OpenAI "How ChatGPT adoption has expanded" 인용 유지. 발표 전 원문 확인 권장(전 리포트와 동일 권고).
- **CherieXX 표기**는 "도입 확정 · 1억 1,500만원 규모" 원문 그대로. "계약 문서화 진행 중" 부기는 넣지 않았다.
- **로컬 `~/orca-projects/thezonebio.com`** 클론은 main을 `7c1f7fb`까지 pull한 뒤 브랜치 작업. 다음 사람은 `git checkout main && git pull`부터.
- 작업 트리의 미추적 `docs/research/competitive-analysis-2026-09.md`는 내가 만든 게 아니라 이번에도 커밋하지 않았다.
- 스크린샷 스크립트(`tmp/shoot.mjs`, `tmp/frags.mjs`, `tmp/live.mjs`)는 `.gitignore`의 `tmp/`에 있어 커밋되지 않음. 필요하면 `scripts/`로 옮겨 커밋.

## 7. 추가 (Min 지시, 11:40 KST) — 커버에 ver1 사진 배경

- **전제 확인:** arcair 전 버전(v2=ver1, v3, v4, v4.1) 커버 어디에도 사진 배경은 없었다(`background-image`/`url(data:` 0건, thezonebio.com 전 커밋 grep). ver1이 가진 사진은 팀 스튜디오 사진과 **ARCA Core 사진(손에 든 Core + ARCA 화면)** 둘. 후자만 다크 커버와 맞아 그걸 썼다.
- **적용:** 커버 오른쪽 64% 풀블리드, 좌→우 그라데이션으로 "arca 해놔." 쪽은 검정 유지, 상→하 그라데이션으로 밝은 웹앱 패널을 눌렀다. 1.4초 페이드인. 커버의 460px Spirit는 뺐다(사진에 ARCA 얼굴이 둘 있고 패널과 겹쳤다). 카피·필·태그·노트 불변. 2~20장 마크업 불변.
- **PR:** arca #13 MERGED (`e7b77ac`), thezonebio.com #8 MERGED. 라이브 `thezonebio.com/arcair` 705,123B `cmp` 동일, ver1 불변. 스냅샷 `public/arcair-v41-backup-20260921/`(사진 없는 v4.1) 추가.
- **스크린샷:** `docs/screenshots/arcair/01.png`, `docs/screenshots/live/thezonebio-arcair-v41-01-cover.png`.
- 6항의 "커버 톤" 항목은 이걸로 닫힘.
