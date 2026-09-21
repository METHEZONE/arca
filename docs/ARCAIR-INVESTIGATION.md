# ARCAIR 정찰 결과 — "arcair", "arcair-ver1", "예전 /arca"가 정확히 무엇인가

작성: 2026-09-21 야간 자율 작업 (Claude Fable 5.1). 브리프: `docs/ARCAIR-OVERNIGHT-BRIEF.md` 0번.

## 결론 한 줄

- **arcair-ver1 (= Min이 좋다고 한 "예전 arcair")** = `https://thezonebio.com/arcair-ver1` = IR 덱 **v02 (23장)**.
  이 저장소 사본: `ir/2026-09-17_business-plan/2026-09-21_ARCA_IR_Deck_v02.html` @ 브랜치 `origin/core-v1-arca-face`, 커밋 `8d710cb`.
  라이브 파일과 git 사본은 **바이트 단위로 동일** (`cmp` 통과, 1,007,764 bytes, `<section>` 23개).
- **arcair (Min이 "별로"라고 한 신작)** = `https://thezonebio.com/arcair` = IR 덱 **v03 (17장 본편 + Q&A 부록 46섹션)**.
  이 저장소 사본: `ir/2026-09-21_zer01ne-ir-v3/2026-09-21_ARCA_IR_Deck_v03.html` @ 같은 커밋 `8d710cb`. 라이브와 바이트 동일.
- **예전 /arca 랜딩** = 커밋 `6352eae` 시점의 `app/arca/page.tsx` + `arca.css` + `layout.tsx` (Spirit 캐릭터 시스템, 스크롤 라이더, 타이핑 루프, 위임 데모 창, 메모리 리콜 데모, MILO/PIXEL/VOX/SILO 에이전트 캐릭터, 프라이싱, 베타/웨이트리스트).
  `8df83ef`("warm-black Personal Life OS rewrite")가 이걸 전면 교체했고, Min이 별로라고 한 게 이 리라이트다.
- 브리프가 추정했던 `ir/arca-fund3/index.html`(fund3-deck 브랜치 v0.1~v0.5)은 **arcair와 무관**. 그건 `thezonebio.com/arcapitch`로 별도 서빙되는 다른 덱이다.

## 근거

### 1. 배포 경로 (thezonebio.com 저장소)
- 도메인 `thezonebio.com`은 별도 저장소 `METHEZONE/thezonebio.com` (Vercel 프로젝트 `thezonebio.com`, `prj_RsMkmxP2LALLkNk0NAE0EalNxK9A`)이 서빙한다.
- `next.config.ts` rewrites:
  - `/arcapitch` → `public/arcapitch/index.html` (fund3-deck 계열)
  - `/arcair` → `public/arcair/index.html` ("ARCA IR 덱 v2 (2026-09 제로원 예비 IR)" 주석이지만, 현재 내용은 v03으로 교체된 상태)
  - `/arcair-ver1` → `public/arcair-ver1/index.html` ("v2 보존본 (2026-09-21 전면 재구성 전 스냅샷)")
  - `/arcair-2` → `public/arcair-2/index.html` (커밋 `558e9aa` "add route for Claude Code/Fable autonomous redesign pass" — 이번 작업용으로 미리 만들어둔 빈 슬롯, 1줄 플레이스홀더)
- 해당 저장소 최근 커밋 순서: `3775801 feat(arcair-ver1): preserve ARCA IR deck v2 snapshot at /arcair-ver1 before 9/21 rebuild` → `d26c4d1 feat(arcair): ARCA IR deck v3 …` → Astra 리뷰 반영 → `93b1ec0` S3B 추가 → `cede2df` 하이브리드 라이트/다크 → `558e9aa` arcair-2 슬롯.
  즉 "기존 arcair"가 ver1로 밀려나고 v3가 arcair 자리에 들어간 흐름이 커밋 로그로 확인된다.
- 라이브 응답 헤더 `x-matched-path: /arcair-ver1/index.html`, `/arcair/index.html` 확인.

### 2. 이 저장소(METHEZONE/arca) 쪽 사본
- `origin/core-v1-arca-face` 브랜치 커밋 `8d710cb` (2026-09-21 08:58 KST)에 v01/v02/v03 HTML + 빌드 파츠 + 야간 리포트(`2026-09-21_ARCA_morning_report.md`)가 들어있다.
- 그 리포트 첫 줄이 정확히 이렇게 적혀 있다:
  > `/arcair-ver1 (보존): https://thezonebio.com/arcair-ver1 — 23장 v2 원본` / `새 /arcair (v3.2): https://thezonebio.com/arcair — 17장 본편 + Q&A 부록`
- v02 감도: 흰 배경 + 오렌지(`#f75b2b`) + 검정 긴장 슬라이드, Pretendard, 1920×1080 고정 스테이지 스케일, `.an` 모션 라이브러리(fadeUp/slideL/slideR/pop/typing/lit/knob/fly…), Spirit 캐릭터 SVG 심볼(`#spirit`, `#spirit-happy`, `#spirit-blue`), Mac/iPhone/Watch/Core 목업, 말풍선, 약속 패킷.
- v03은 같은 토큰을 쓰지만 홀드 프레임, HUD 타이머, 부록 46섹션, 발표자 노트 등으로 구조가 훨씬 무거워졌고 톤이 "IR 문서체"로 바뀌었다.

### 3. 랜딩
- `app/arca/page.tsx` 히스토리: `4a4f6e7`(최초) → `61be4a5`(Beta edition, 플로팅 ARCA, OG 이미지) → `6352eae`(TestFlight 링크를 다운로드 트래킹 API로) → `8df83ef`(warm-black 전면 리라이트).
- 복원 베이스는 **`6352eae`** (리라이트 직전 마지막 상태). `4a4f6e7`~`61be4a5` 차이는 Beta 섹션과 OG 이미지 추가 정도이고 캐릭터 시스템은 동일하다.
- `8df83ef`가 함께 바꾼 Google 콜백/온보딩 파일은 웹앱 기능이라 그대로 둔다. 랜딩 3파일만 복원.

## 이번 작업에서의 취급

| 대상 | 취급 |
|---|---|
| `thezonebio.com/arcair-ver1` (v02) | **손대지 않음.** 다른 저장소이고, Min 지시 "그대로 유지". |
| ver1 소스 사본 | `ir/arcair-ver1/index.html`에 v02 원본을 그대로 복사해 이 저장소에도 보존 (참조용, 바이트 동일). |
| 새 arcair | `ir/arcair/index.html` — v02를 베이스로 복사한 뒤 새 스크립트(S0~S15) 반영, 카피 키치하게 재작성. |
| `/arca` 랜딩 | `6352eae` 버전으로 복원. 라이브 웹앱(`/arca/onboarding`) 진입 CTA만 최소 추가. |
| `ir/arca-fund3/` (arcapitch) | 건드리지 않음. |
| 배포 | Vercel CLI 미로그인(`auth.json` 비어 있음). thezonebio.com 저장소에 `/arcair-2` 슬롯이 이번 작업용으로 준비돼 있으나 그 저장소 main에 직접 푸시하는 건 프로덕션 반영이라 하지 않음. 리포트에 배포 절차만 명시. |
