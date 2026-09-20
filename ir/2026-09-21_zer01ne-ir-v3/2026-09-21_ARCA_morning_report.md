# ARCA 9/21 야간 구현 리포트 (2026-09-21 06:20 KST)

## URLs
- /arcair-ver1 (보존): https://thezonebio.com/arcair-ver1 — 23장 v2 원본, 애니메이션·이미지 60장·Pretendard 로드 확인
- 새 /arcair (v3.2): https://thezonebio.com/arcair — 17장 본편 + Q&A 부록(Index, B01–B25, A01–A03) = 46 섹션
- 새 /arca 랜딩: https://thezonebio.com/arca
- 웹앱: https://arca-the-zone-bio.vercel.app/arca/app (로그아웃 상태면 /arca/onboarding → Continue with Google)
- 정적 PDF 폴백(50p): artifacts/2026-09-21_ARCA_IR_Deck_v03_static.pdf
- 소스/빌드: artifacts/2026-09-21_ARCA_IR_Deck_v03.html, Drive `더존바이오/Project ARCA/arca/ir/2026-09-21_zer01ne-ir-v3/`

## 덱 조작
→/Space 다음(홀드 프레임 포함) · ← 이전 · A 부록 Index · 숫자 두 자리 → Bxx 점프(예: 1,9) · Esc Index · B 직전 질문 · N 발표자 노트 · C 9:25 컷/전체 스크립트 전환 · T 타이머 · F 전체화면 · ?print=1 정적 · ?autoplay=1 리허설 자동재생(부록 미진입)

## 구현 완료 / Prototype / 미완료
### 완료 (Live)
- /arcair-ver1 보존, 새 /arcair 17장(S0–S14, S6A, S12A) 전면 재구성, 모션 언어 전부 구현(count-up, 창 증식·fracture, 노드 순차 점등·path growth, drag→orange region, pulse, evidence lock, consent/quality 분리 레일→Taste Model, 경쟁표 ARCA 행·핵심 열 마지막 점등, TAM 원·bottom-up 막대 수렴, private graph 간 scoped packet, ARCA Moment)
- S5 6개 홀드 프레임(시작·목표 / 범위 / 경계 질문 / 증거 / 피드백 분리 / Shared ARCA)
- 부록: 질문 Index(9그룹) → B01–B25 2초 내 점프, 각 장 Index/직전 질문 버튼, 한 장 한 질문, 첫 화면 한 문장 → 클릭 시 deeper → evidence/calc → boundary reveal, measured/proxy/assumption/target 라벨, base/conservative/upside(B17·18·19·20·21·24), 하단 source strip, 노트에 likely follow-up + 안전 문장, A01 계산식(로드 시 재계산) · A02 출처 · A03 답변 순서
- /arca 랜딩(warm-black/orange, 세 가지 전환, 코어 루프 7비트 자동재생, A2A scoped packet, Company Brain AX = Work Shell, Live/Prototype/Coming next 스트립, Google 로그인 CTA 3곳)
- 웹앱: Google 로그인(profile scope) → identity onboarding(공개 신호: Gravatar + 도메인 홈페이지, 후보+출처+confidence, 확인/수정/삭제) → 캡처(붙여넣기·브라우저 녹음→whisper) → Claude 약속 추출(요약·인용·7노드 경로) → “ARCA it?” → Commitment Graph drag 범위 → 범위 안 실행(경계 질문 승인/수정/거절, LLM 초안 실제 생성) → 증거 붙여넣기로 lock → consent/quality 피드백 분리 저장 → 연결 소스 상태 → Postgres 영속(새로고침 유지)
### Prototype (UI 라벨 표시)
- 외부 증거 수동 붙여넣기(Gmail/Calendar/결제 어댑터 없음), Taste Model 기록만(제안 반영 X), A2A 6단계 시뮬레이션(상대 사용자 없음, PR #6 데모 근거)
### Coming next
- Gmail 발송/회신 증거, Calendar 수락 증거, Slack, 결제·배송 어댑터, Core 하드웨어

## QA 결과
- Desktop(1440/1920 스케일): 53 프레임 overflow/clipping 검사 — 겹침 0(스탬프·힌트 위치 수정 완료). 이미지 27개 깨짐 0, JS 오류 0.
- Mobile: 가로(812×375) 정상 판독, 세로(375×812)는 레터박스 + “가로로 돌려서” 안내(16:9 덱 특성상 degraded).
- Projector: 모든 본편 슬라이드 핵심 문장 ≥40px, 핵심 숫자 ≥72px, 본문 최소 16–19px, 각주 15–17px.
- 정적 폴백: 모든 요소 최종 상태 기본 + 애니메이션은 active에서만 → ?print=1 / PDF 동일 장면. reduced-motion 대응.
- 부록 자동 진입 방지: m17 끝에서 → 눌러도 유지(“A = Appendix” 힌트), autoplay도 m17에서 정지.
- 부록 왕복: Index→B07→3레이어→B08, 직전 질문 버튼→B07, Index, 숫자 점프 19→B19, Esc→Index, ←→m17 엔드카드 — 전부 확인. #b25, 레거시 #5 해시 라우팅 확인.
- 수식 재계산(JS 단일 소스 F): TAM 3,734,006,209×20%×154,800 = 115,604,832,230,640 ≈ 115.6조 · SAM (171.495M+29.154M)×15%×154,800 = 4,659,069,780,000 ≈ 4.66조 · SAM users 30,097,350 · 10,000/30,097,350 = 0.0332% · ladder 1,548만/1.548억/15.48억 · 전사 14,400분×$0.003–0.006 = $43.2–86.4 (구 문서의 43,200분 오류 정정 표기).
- 출처 URL 15개 전부 응답(OpenAI 403·Morningstar 202는 봇 차단, 브라우저 정상). Stanford AI Index 2026 원문 재대조: “Generative AI reached 53% population adoption within three years, faster than the PC or the internet” · “Organizational adoption reached 88%” 확인.

## 발표 타이밍
- 소스 문서의 장별 목표 합계는 9:55(문서 표기 9:25와 30초 불일치) → HUD 목표를 S2/S5/S6/S6A/S7/S12A에서 5초씩 줄여 9:25로 설정.
- 원고 전체(4,592자) 발화 추정 13:55(330자/분)~15:18(300자/분) → 10분 초과 위험 큼.
- 노트에 “9:25 컷 스크립트” 내장(3,077자 → 9:19 @330자/분, 10:15 @300자/분). C 키로 전체/컷 전환, 컷 문장은 전체 모드에서 취소선으로 표시. 컷은 화면에 이미 있는 숫자·규칙 문장과 소스 문서의 fallback(S11 한 문장, S9 딜 카드, 시장 산식 결론만) 기준. 원문 문장은 삭제하지 않았음.

## Astra 독립 검증 (OpenAI gpt-5.4 vision, 17장 스크린샷 + 전체 텍스트 + 부록) — ready-with-fixes
반영(재현 가능한 것만):
- S0 화면의 질문 문구 제거(소스: 질문은 spoken) → 커버 한 주장
- CherieXX 표기 통일: “도입 확정 · 계약 문서화 진행 중”(S6·S9), S8 막대에서 CherieXX 제거(증명은 S9만)
- κ-bench에 “methodology v0.3 · 성능 결과 없음” 배지, 경쟁 맵 ARCA에 “target position · 제품 설계” 배지, S12A “SOM: 채널 실측 전 미확정” 배지, S8 원가에 scenario 라벨
- S9 Netty 숫자 축소·pipeline 배지 강조
- S13 사용처 배분을 v1 덱의 working allocation(45/30/10/15%)으로 교체, 본편 각주의 “[확인 필요]”·현대/YC/a16z 문구를 노트로 이동
- S6A(경쟁) 한 문장 헤드라인 추가, 레이아웃 이동
- 부록 Index에 “본편 → 방어 카드” 매핑 추가
미반영(의도적): 한 장 다중 요소(S5·S6A·S12A)는 소스 문서 지시대로 유지(S5는 홀드 프레임으로 한 프레임 한 주장) · 경쟁→과학 순서는 소스 순서 유지 · B26+ 신설 대신 SAFE 조건/런웨이·ICP·법인 구조 질문은 B24/B20/B13 follow-up으로 흡수(B01–B25 사양 유지). Astra 지적 “12%” 표기는 캡처 타이밍 아티팩트(실제 53% 카운트업 확인).
- 랜딩(gpt-5.4-mini): VISUAL 4/5, 30초 이해 yes, 로그인 경로 yes. 온보딩: WOW 4/5, CREEPY 2/5(출처·confidence·확인·수정 경로 노출 확인).

## Core flow E2E (프로덕션, 내가 직접 재실행 06:00 KST)
새 회의록 붙여넣기 → claude 추출(요약+2 약속, 인용 포함) → “ARCA it?” → /arca/app/c/… 7노드 → drag 약속→수신 확인 대기 = 6단계 범위(authorized) → 범위 안 실행 → #1 원문 증거 lock → #2 경계 질문 “단가 범위…” → consent ‘묻고 할 것’ → 승인 → #3 Claude 초안 실제 생성(이지현 팀장 수신, THE ZONE BIO 박민성 발신) → quality ‘내 기준에 맞았다’ → 승인 → #5 발송 “Gmail 발송 · Coming next” 정직 차단 → 링크 증거 붙여넣기 → lock(잠긴 노드 2/7 · 외부 증거 1) → 새로고침 후 유지 → A2A 페이지 Prototype 라벨 확인 · 미로그인 curl: /api 401, /arca/app 307 → onboarding.


## 추가 반영 (06:40 KST) — 창업가 시그널 강화 (사용자 지시: 보수적일 필요 없음)
- 새 슬라이드 **S3B Founder Track Record**(m4b, 20s) 추가 → 본편 18장, HUD 목표 합계 9:29(S1/S4/S11/S12에서 16초 절감).
  - 사진: 2025 정주영 창업경진대회 데모데이 시상식(우수상 플래카드, 무대 브랜딩) + 본선 피치 무대 사진 — Drive `40_LIBRARY/04_MEDIA_ARCHIVE/행사사진영상/2025.10.28_정주영창업경진대회` 원본에서 선별(vision 리뷰로 7+8장 중 최적 선택).
  - 카운터: 엑싯 1 · 수상/선정 8 · 인터뷰 40+ · 교육 6년. 리스트: 정주영 우수상(1,200+팀) · 창업중심대학 1위(사업비 1억)·예비창업패키지 최우수 · YC(Browser Use) Best Design · AWS Agents 2위 · Google Cloud×Solana 3위 · THE 해커톤 본선·500 Global 3위 · Milo's 창업→매출 1억→엑싯 · 이력(연세대 CTM·UBC·AI MELODY CTO·Hebronstar·샘표·Perplexity Campus Strategist).
  - 시그널 pill: **a16z Speedrun SR008 · zerobase referral · 서류 통과 · 인터뷰 예정** · ZER01NE Sprint 2026 · 개발 1개월 만에 첫 엔터프라이즈 도입 확정.
  - 출처: 창업자 사업계획서 v01(2026-09-17, ZER01NE 발송본)·투자심사 자료 회신(2026-09-13/16). zerobase referral 근거: zerobase 메일 "if we refer you, you skip the speedrun application stage"(2026-03-13) + zerobase korea season 5 참가.
- S12 Team: 박민성 bio에 엑싯·수상·a16z 인터뷰 예정 추가, 하승호에 대한민국인재상·HP 사내벤처 CEO 추가.
- S13 Ask: “라운드 시그널” 스트립(a16z Speedrun 인터뷰 예정 · ZER01NE 예비 IR · 현대 1억 가능성 · 글로벌 VC 구성).
- B25: a16z 문구를 “referral로 서류 통과·인터뷰 예정까지 말한다(선정·투자 아님)”로 갱신.
- 경계 유지: 특허/논문은 본편에서 말하지 않음(사업계획서엔 ‘출원 [진술]’, 소스 문서엔 ‘준비 중’으로 상충). 500 Global 연도는 문서 간 상충(2023/2024)이라 연도 생략.
- 정적 PDF 51p 재생성. 라이브 확인: https://thezonebio.com/arcair#m4b (5/18).


## 추가 반영 (07:20 KST) — 하이브리드 라이트/다크 (사용자 지시)
- 색을 전부 토큰화(--bg/--panel/--card/--chip/--node/--line/--ink/--t1/--t2/--mut/--dim …) 후 `section.s.lt` 라이트 테마 추가. 기본(:root)은 다크 유지.
- **검정(긴장 구간 5장)**: S0 커버 · S2 The Hidden Cost · S5 Commitment Graph(제품 시그니처 6프레임) · S13 Ask · S14 Vision Finale.
- **흰색(정보 구간 13장 + 부록 전체)**: S1 통계 · S3 Founder Insight · S3B Founder Track Record · S4 문제 · S6 트랙션 · S6A 경쟁 · S7 구조 · S8 BM · S9 Commercial Proof · S10 GTM · S11 Expansion · S12 Team · S12A 시장 · Q&A Index/B01–B25/A01–A03.
- 라이트 전용 보정: 로고 칩 흰 배경+그림자, O/△/X·배지·스탬프·라벨 색을 진한 버전으로(#9a6400/#12803f/--od), 오렌지 소형 라벨은 --od(#dc5000)로 대비 확보, 부록 chrome(abar/srcstrip/layer/버튼) 강화, 문제 카드 아이콘 stroke 4로.
- QA: 전 슬라이드(46장, 53프레임) overflow 0 · 자동 대비검사에서 실제 저대비 항목 0(남은 플래그는 반투명 배경 오탐) · 다크 5장 시각 검수 통과 · 정적 PDF 51p 재생성(흰 배경 기준).
- 남은 관찰: 커버(다크)→본문(라이트) 전환이 다소 급하다는 리뷰어 의견. 필요하면 S1을 다크로 한 장 더 물리거나 커버를 라이트로 바꿀 수 있음(1분 작업).

## 남은 blocker / 다음 우선순위
1. 발표 원고 길이: 전체 원고는 14~15분. 아침에 C(컷 모드)로 1회 리허설하고 T 타이머로 실측 필요. 컷 문장 선택은 내 판단 — 검토 후 조정 가능.
2. 소스 문서 “확인 필요” 항목은 그대로 남음: CherieXX 서명/입금, 40명 인터뷰 표, a16z/YC 원문, 현대 1억 조건, 12개월 가정표, SAFE 조건·런웨이(Astra도 최우선 지적).
3. 웹앱: 브라우저 녹음→whisper 경로는 실제 오디오로 미검증(시연은 붙여넣기 권장). 로컬 .env Anthropic 키 크레딧 없음(프로덕션은 정상). 세션 쿠키는 arca 오리진에 있어 thezonebio.com/arca/app 직접 진입 시 arca 오리진 로그인으로 리다이렉트됨.
4. 모바일 세로는 축소 판독(가로 권장). 프로젝터에서 각주(15–17px)는 읽히지 않아도 되는 수준으로 설계.
5. 다음: Gmail/Calendar 증거 어댑터(Coming next 해제), Taste Model을 제안에 반영, A2A 실제 2사용자 인스턴스.
