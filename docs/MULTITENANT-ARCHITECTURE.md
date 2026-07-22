# ARCA 멀티테넌트 아키텍처 설계

> 2026-07-23 · 상태: 설계안 v1 (구현 전 검토용)
> 목표: "박민성의 ARCA" → "누구나 다운로드해서 구글 로그인 → 커넥터 연결 → 바로 쓰는 ARCA"

## 1. 지금 어디까지 와 있나 (현재 구조 실측)

멀티테넌트로 가는 부품의 절반은 이미 코드에 있다.

| 부품 | 현재 상태 | 파일 |
| --- | --- | --- |
| 로컬 멀티계정 | ✅ 있음 — `ArcaAccount` 레지스트리(~/.arca/accounts.json), 계정별 sessions/·connections.json·SwiftData 스토어 완전 분리 | `AccountStore.swift`, `SessionPaths.swift` |
| 커넥터 OAuth | ✅ 있음 — Composio v3 `connected_accounts/link`로 8개 툴킷(Gmail·GCal·Drive·Slack·Notion·GitHub·Linear·Todoist) redirect URL 발급 | `ConnectorHub.swift` |
| 커넥터 실행 | ✅ 있음 — `tools/execute/{TOOL}` 직접 호출 (캘린더 생성, Gmail 발송, 컨텍스트 pull) | `ComposioCalendar.swift`, `SummaryEmailSender.swift`, `ConnectorHub.swift` |
| 신원(identity) | ❌ 없음 — `composioUserId`는 수동 세팅된 문자열, 로그인 없음 | `ArcaConfig.swift` |
| 시크릿 배포 | ❌ 개인용 — Composio **프로젝트 API 키**가 각 기기 Keychain/BYOK로 존재 | `KeychainStore`, `BundledKeys.plist` |
| 서버 | ❌ 없음 — 앱이 backend.composio.dev와 직접 통신 ("no ARCA server in the loop") | `ConnectorHub.swift` 주석 |

**핵심 격차는 딱 두 개다:**
1. **신원**: user_id가 "구글 로그인으로 검증된 나"가 아니라 로컬 문자열이다.
2. **신뢰 경계**: Composio 프로젝트 API 키는 마스터 키라(모든 유저의 connected account로 tool 실행 가능) 클라이언트에 배포하면 안 된다. 지금은 내 기기뿐이라 괜찮지만, 배포하는 순간 전 유저 데이터 열쇠를 나눠주는 꼴이 된다.

## 2. 목표 아키텍처

```
┌────────────── 사용자 기기 (Mac/iPhone) ──────────────┐
│ ARCA.app                                             │
│  · Google Sign-In (ASWebAuthenticationSession)       │
│  · ARCA 세션 토큰 보관 (Keychain)                     │
│  · 녹음/전사/노트 = 전부 온디바이스 유지               │
│  · LLM 키 = 당분간 BYOK 유지 (아래 §6)                │
└───────────────┬──────────────────────────────────────┘
                │ HTTPS (ARCA 세션 토큰)
┌───────────────▼──────────────────────────────────────┐
│ ARCA Cloud (기존 Next.js 앱에 API 라우트 추가)         │
│  /api/auth/*        Google OAuth → 세션 발급          │
│  /api/connect/:tk   Composio link URL 발급 (프록시)    │
│  /api/connections   내 연결 목록                       │
│  /api/tools/:slug   tool 실행 프록시 (allowlist)       │
│  DB: users, sessions (Vercel Postgres/Supabase)       │
│  비밀: COMPOSIO_API_KEY (서버에만 존재)                │
└───────────────┬──────────────────────────────────────┘
                │ x-api-key (프로젝트 키)
        ┌───────▼────────┐
        │ Composio v3    │  user_id = "g:{google_sub}"
        │ (계정당 CA 격리)│  connected_account 단위 권한
        └────────────────┘
```

**원칙: 서버는 얇게.** 회의 데이터·전사·노트는 절대 서버로 올리지 않는다(온디바이스 그대로). 서버가 하는 일은 (a) 구글 로그인 신원 발급, (b) Composio 마스터 키 은닉 + user_id 스코핑, (c) tool 실행 프록시의 allowlist 검증 — 이 세 가지뿐. ARCA의 "내 데이터는 내 기기에" 포지셔닝을 지키면서 신뢰 경계만 세운다.

## 3. 신원 설계

- **user_id 규약**: `g:{google_sub}` (구글의 불변 subject ID). 이메일은 표시용으로만 — 이메일은 바뀔 수 있고 sub는 안 바뀐다.
- **로그인 플로우 (Mac/iOS 동일)**:
  1. 앱 → `ASWebAuthenticationSession`으로 `https://thezonebio.com/api/auth/start?device=...` 오픈
  2. 서버가 Google OAuth (openid email profile) 수행 → 콜백에서 유저 upsert → 일회성 코드로 `arca://auth?code=...` 커스텀 스킴 리다이렉트 (URL 스킴 `arca`/`arca-test` 이미 등록돼 있음)
  3. 앱이 코드를 `/api/auth/exchange`로 교환 → 장수명 세션 토큰(기기당 1개) → Keychain 저장
- **로컬 계정과의 접합**: 로그인 성공 = `AccountStore`에 계정 upsert (`id = g:{sub}` 축약 슬러그, email/displayName 채움). 기존 "default" 계정은 그대로 두고 마이그레이션 UI에서 "이 데이터를 내 구글 계정으로 연결" 1회 제공. **SessionPaths/스토어 파티셔닝은 이미 계정 단위라 추가 작업 없음** — 이게 이번 설계의 최대 지렛대다.
- **게스트 모드 유지**: 로그인 없이도 녹음/전사/로컬 기능은 전부 동작 (BYOK). 로그인은 커넥터·동기화의 게이트일 뿐.

## 4. 커넥터 설계 (Composio)

- **연결**: 앱의 `ConnectorHub.connectURL(for:)`을 서버 프록시 호출로 교체:
  - `POST /api/connect/GMAIL` → 서버가 (auth_config 조회 + link 생성)을 서버 키로 수행, `redirect_url` 반환. 앱은 브라우저로 오픈 — 지금 UX 그대로.
  - 콜백 후 `GET /api/connections` 폴링(또는 앱 포그라운드 시 refresh)으로 ACTIVE 반영 — 현 `refresh()` 로직 이식.
- **실행**: `POST /api/tools/GOOGLECALENDAR_CREATE_EVENT` → 서버가 세션 토큰에서 user_id를 뽑아 connected_account를 **서버 DB 기준으로** 해석해 Composio에 전달. 클라이언트는 connected_account_id를 알 필요도, 보낼 권한도 없어진다.
- **Allowlist**: v1 프록시는 지금 앱이 실제 쓰는 툴만 통과: `GOOGLECALENDAR_CREATE_EVENT`, `GOOGLECALENDAR_EVENTS_LIST`, `GMAIL_SEND_EMAIL`, `GMAIL_FETCH_EMAILS`, `GOOGLEDRIVE_LIST_FILES`, `SLACK_SEARCH_MESSAGES`, `NOTION_*(사용분)`. 나머지는 403. 유저당 rate limit(예: 60 req/min).
- **클라이언트 변경 최소화 전략**: `ComposioCalendar`/`SummaryEmailSender`/`ConnectorHub`의 endpoint와 인증 헤더만 갈아끼우는 `ArcaCloudTransport` 프로토콜을 도입 — 로그인 상태면 ARCA Cloud로, 아니면(개인 BYOK 모드) 기존 직통 Composio로. **기존 개인 셋업이 계속 동작하는 채로 멀티테넌트가 얹힌다.**

## 5. 서버 구현 스펙 (Next.js — 이 리포의 앱에 추가)

- 라우트: `app/api/auth/{start,callback,exchange}/route.ts`, `app/api/connect/[toolkit]/route.ts`, `app/api/connections/route.ts`, `app/api/tools/[slug]/route.ts`
- DB 스키마 (최소):
  - `users(id uuid, google_sub text unique, email, name, created_at)`
  - `device_sessions(token_hash, user_id, device_label, last_seen, revoked)`
  - connected accounts는 **DB에 저장하지 않는다** — Composio가 원본(`GET /connected_accounts?user_ids=g:{sub}`), 캐시만 메모리/짧은 TTL.
- 환경 변수: `GOOGLE_CLIENT_ID/SECRET`, `COMPOSIO_API_KEY`, `SESSION_SECRET`.
- 감사 로그: tool 실행 프록시는 (user, tool, ts, ok/err)만 남긴다 — 인자/응답 본문은 저장 안 함(개인정보 최소화).

## 6. 단계별 로드맵

| 단계 | 내용 | 리스크 |
| --- | --- | --- |
| **P0 (지금)** | 설계 승인 + Google OAuth 클라이언트/Composio 프로젝트 정리 | — |
| **P1** | Next.js에 auth 3종 + 세션 발급, 앱에 Google Sign-In 버튼(설정 탭) → AccountStore 접합 | 콜백 스킴/샌드박스 |
| **P2** | connect/connections/tools 프록시 + `ArcaCloudTransport` 스위치, ConnectorsView는 그대로 | Composio API 셰이프 (이미 실측 주석 있음) |
| **P3** | TestFlight 외부 테스터 2–3명으로 실전 검증 (신규 기기 → 로그인 → Gmail/GCal 연결 → 회의록 이메일 루프) | 온보딩 UX |
| **P4 (보류 결정)** | LLM 키 서버 프록시(BYOK 제거, usage billing), iPhone↔Mac 동기화의 GitHub relay → ARCA Cloud 이전 | 비용/과금 설계 필요 |

LLM 키는 P4로 미룬다: BYOK는 지금도 동작하고, LLM 프록시는 과금 모델(크레딧? 구독?)이 정해져야 의미가 있다. 커넥터 신뢰 경계가 먼저다.

## 7. 이번 세션에서 이미 맞춰둔 것

- 챗 `[CALENDAR:]` 액션·회의별 챗·로스터 인식 전부 `ComposioCalendar.fromArcaConfig()` 계열 단일 관문(`CalendarEventCreator`)을 지나므로, P2에서 transport만 바꾸면 전 기능이 멀티테넌트로 따라온다.
