# ARCAIR 오버나잇 리포트 — 2026-09-21 (Claude Fable 5.1)

브랜치 `arcair-overnight-rework` · Draft PR **https://github.com/METHEZONE/arca/pull/11** · main에 머지하지 않았음.

## 한 줄 요약

ver1(=v02 덱)은 그대로 두고, 그 뼈대 위에 새 스크립트(S0~S15)로 19장 덱을 다시 썼다. `/arca` 랜딩은 Spirit 캐릭터가 살아있던 `6352eae` 상태로 복원했다. typecheck/lint/build 전부 통과. 스크린샷 23장. Vercel 프리뷰는 GitHub 연동으로 자동 생성됨.

## 1. 무엇을 ver1 / arcair로 확정했나 (근거는 `docs/ARCAIR-INVESTIGATION.md`)

| 이름 | 실체 | 이 저장소 위치 | 처리 |
|---|---|---|---|
| **arcair-ver1** ("예전 arcair", Min이 좋다고 한 것) | IR 덱 **v02 · 23장** · `thezonebio.com/arcair-ver1` | `ir/arcair-ver1/index.html` (라이브와 `cmp` 바이트 동일) | **손대지 않음** |
| **arcair** (신작, "별로") | IR 덱 **v03 · 17장+부록** · `thezonebio.com/arcair` | (core-v1-arca-face 브랜치 `8d710cb`에만 존재) | 이 저장소에서 `ir/arcair/index.html`을 v02 기반 신작으로 교체 |
| 예전 `/arca` 랜딩 | 커밋 `6352eae` (`8df83ef` warm-black 리라이트 직전) | `app/arca/page.tsx`, `arca.css`, `layout.tsx` | 복원 |
| `ir/arca-fund3/` | `/arcapitch` (다른 덱) | — | 무관, 미변경 |

근거: thezonebio.com 저장소 `next.config.ts` rewrites(`/arcair`, `/arcair-ver1`, `/arcair-2`, `/arcapitch`) + 커밋 로그(`3775801 preserve v2 at /arcair-ver1` → `d26c4d1 v3` → …) + 라이브 HTML과 git 사본 `cmp` 일치 + v03 야간 리포트 첫 줄("/arcair-ver1 (보존): 23장 v2 원본").

## 2. 랜딩 복원 (커밋 `63e70d6`)

- `git show 6352eae:app/arca/{page.tsx,arca.css,layout.tsx}` 그대로. Spirit(커서 따라가는 눈, bob/blink, party 모드), 스크롤 라이더, `arca it —` 타이핑 루프, 위임 데모 창, 메모리 리콜 데모, MILO/PIXEL/VOX/SILO 캐릭터 에이전트, 디바이스 호퍼, 프라이싱, Mac 베타 신청, 웨이트리스트, OG 메타데이터("Your Second Self") 전부 복귀.
- 위에 얹은 변경 2줄: "Not a mockup — open the web app →" 버튼과 nav "Web app" 링크가 `/arca/onboarding`(웹앱 Google 로그인)으로 감. 예전엔 `/`(구 캡처 앱)이었음.
- `8df83ef`가 함께 바꾼 Google 콜백/온보딩 파일은 웹앱 기능이라 유지.

## 3. IR 덱 (커밋 `568fa07`) — `ir/arcair/index.html`, 19장

v02의 `<head>`(토큰, 모션 라이브러리, Spirit 심볼, Mac/iPhone/Core 목업 CSS)와 이미지 60장 중 15장을 그대로 쓰고 본문만 새로 썼다.

| # | 슬라이드 | 핵심 |
|---|---|---|
| 1 | S0 커버 (dark) | "arca 해놔." · "AI한테 일 시키는 건 이제 누구나 해요. 그 일, 끝까지 누가 봐요?" |
| 2 | S1 AI Explosion | 53% 카운트업, +50% / 2×, 확산 곡선. 출처 Stanford HAI AI Index 2026 · OpenAI |
| 3 | S2 Hidden Cost (dark) | "AI는 싸졌는데, 나는 왜 더 바빠졌지." 탭 9개 Mac 목업, 사람=main thread 루프 |
| 4 | S3 Founder Insight | 터미널 10개 그리드(닫힘/마감 직전/놓침/완성도↓), 40명+ 인터뷰, "먼저 살다가 문제를 밟은 사람" |
| 5 | S4 세 가지 문제 | 컨텍스트 찢김 / 내 현실·기준 모름 / 실행은 에이전트, 관리는 나 |
| 6 | S5a Solution (dark) | Personal Life OS 정의 + **★ coordination state / policy setter 문단 원문 그대로** 카드 |
| 7 | S5b 네 가지 구조 | **★ Re-entry · Polling · Next-step prompting · Verification "제거" 카드 4장** + "이해가 먼저" 문단 |
| 8 | S5c **핵심 모먼트** (dark) | 13초 자동 재생: 미팅 전사 → **"ARCA it? 초안 쓰고 → 승인받고 → 보내고 → 회신 확인까지 제가 처리하고 보고드릴게요. 괜찮을까요?"** → Commitment Graph 드래그 범위 → 경계 질문(단가 조정) → 외부 증거 잠금 → **"마음에 들었던 메일 하나만 던져주실래요? 레퍼런스로 쓸게요."** R키 재생 |
| 9 | S5d 학습 분리 | consent 레일 vs quality 레일 → "쓸수록 그 사람 기준에 맞아진다" |
| 10 | S6 Traction | 57.7h · 155건 · 46일 · 56개 (v02 수치 그대로), 9월 베타 10명, 북극성 = 개입↓ 완결↑ 애니메이션, Vitamin→Habit→Dependency, "PMF 주장 안 함" |
| 11 | S7 Science | detected→…→verified 상태 기계, "모델은 제안만", κ-bench 5게이트 (methodology v0.3 · 성능 결과 없음 배지 유지) |
| 12 | S8 BM | 개인 구독 + ARCA AX 지금 / 마켓플레이스·리베이트·하드웨어 점선 / 원가 3단 / "검증된 완결 1건당 컴퓨트" |
| 13 | S9 Commercial Proof | CherieXX **1억 1,500만원** 확정 · 두 번째 **400만원** 체결 앞 · "PMF로 포장 안 함" |
| 14 | S10 GTM | 위임 1 = 초대 1 (Spirit 체인), 첫 코호트, ARCA로 ARCA 팜 스테퍼, 채널 로고 |
| 15 | S11 A2A (dark) | v02 9장 비주얼 재사용 + 요청·권한·조건·증거 패킷, 사람 지우는 자동화 아님 / coordination tax / Work Shell |
| 16 | S12 Expansion | Core+BLE+폰 목업 재사용, "같은 완결 레이어가 닿는 현실의 범위" |
| 17 | S13 Team | 셋 소개 + v02 트랙레코드(논문·특허 문구는 제외) + 팀/Core 사진 |
| 18 | S14 Ask | **5억 SAFE**, 용처 3(채용·HW R&D·컴퓨트), 12개월 지표 4, 현대 1억 + 글로벌 VC 구조 |
| 19 | S15 Finale (dark) | ChatGPT → OpenClaw → **ARCA moment**, "혼자일 때는 내 약속을, 연결되면 우리의 약속을", spirit-happy |

- 카피 원칙: 구어체, 짧게, 따옴표 인용, "~합니다" 벽 제거. 숫자·계약·투자 요청액·S5 두 문단은 의미 불변.
- 조작: ←/→ 이동 · **N 발표자 노트**(각 장 하단에 원고 문장 내장) · R 다시 재생 · F 전체화면 · `?print=1` 정적.
- 뺀 것: v02 부록 A1~A3(9/17 기준 상태표라 웹앱 현황과 어긋남), v03의 S3B 창업자 사진 장. 필요하면 재추가 쉬움.
- 덱 파일은 `public/arcair/index.html`에도 복사해 Vercel 프리뷰에서 바로 열림 (정본은 `ir/arcair/`).

## 4. 검증

| 항목 | 결과 |
|---|---|
| `npm run typecheck` | 통과 |
| `npm run lint` | 통과 (사전 존재 에러 1건 `app/arca/app/capture/page.tsx` `window.location.href` 대입 → `assign()`으로 수정, 커밋 `d3ec2a4`. 경고 43건은 기존 코드, 미수정) |
| `npm run build` | 통과 (Turbopack, 21 페이지) |
| 덱 렌더 | Playwright+Chrome 1920×1080, 19/19 장 요소 overflow 0, JS 에러 0 |
| 랜딩 렌더 | 1440 데스크톱 / 375 모바일, 가로 overflow 없음, 웹앱 CTA 2곳 `/arca/onboarding` 확인 |

수정한 렌더 버그: `.mac.big` 클래스명이 `.big{font-size:260px;letter-spacing:-0.07em}`과 충돌해 8장 전체 글자가 겹쳐 보였음 → `.mac.wide`로 분리. S2 창 잘림, S5c 토스트 겹침(순차 등장/퇴장으로 변경)도 잡음.

## 5. 스크린샷

- 덱: `docs/screenshots/arcair/01.png` ~ `19.png` (8장은 13.5초 시점 = 장면 완료 상태)
- 랜딩: `docs/screenshots/landing/desktop-1440-hero.png`, `desktop-1440-full.png`, `mobile-375-hero.png`, `mobile-375-full.png`

## 6. 링크

- Draft PR: https://github.com/METHEZONE/arca/pull/11
- Vercel 프리뷰 (GitHub 연동 자동 생성, 브랜치 URL):
  - 랜딩: https://arca-git-arcair-overnight-rework-the-zone-bio.vercel.app/arca
  - 덱: https://arca-git-arcair-overnight-rework-the-zone-bio.vercel.app/arcair/index.html
  - 이 리포트 커밋 푸시 이후 빌드가 끝나야 최신이 반영됨. 상태는 PR의 Vercel 체크에서 확인.

## 7. 막힌 것 / 안 한 것 (정직하게)

- **Vercel CLI 로그인 없음** (`~/Library/Application Support/com.vercel.cli/auth.json` = `{}`). `vercel --prod=false` 직접 실행은 못 했고, 위 프리뷰 URL은 GitHub 연동이 만든 것.
- **thezonebio.com/arcair 실제 교체는 안 함.** 그 도메인은 `METHEZONE/thezonebio.com` 저장소가 서빙한다. 그쪽엔 이번 작업용 빈 슬롯 `/arcair-2`(커밋 `558e9aa`)가 있다. 반영 절차: `ir/arcair/index.html` → 그 저장소 `public/arcair-2/index.html`(또는 `public/arcair/index.html`)로 복사 후 push. 다른 저장소 main에 프로덕션 반영이라 내 판단으로 하지 않았다.
- **ver1 도메인은 아무것도 건드리지 않았다.**
- 덱의 "+50% / 2×" 출처는 v03 소스에 적힌 OpenAI "How ChatGPT adoption has expanded"를 그대로 인용했다. 발표 전 원문 재확인 권장 (v03 리포트도 같은 권고).
- CherieXX 표기: 스크립트 원문대로 "도입 확정 · 1억 1,500만원 규모". v03 Astra 리뷰가 권한 "계약 문서화 진행 중" 부기는 넣지 않았다. 필요하면 S9 한 줄 추가.
- 작업 트리에 있던 미추적 파일 `docs/research/competitive-analysis-2026-09.md`는 내가 만든 게 아니라 커밋에 넣지 않았다.
