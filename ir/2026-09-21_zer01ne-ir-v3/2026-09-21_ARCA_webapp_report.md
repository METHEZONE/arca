# WEBAPP REPORT — /arca landing (P0-2) + web app core loop (P1)

Repo: /Users/minsungpark/orca/workspaces/arca/plankton (METHEZONE/arca, main). Vercel project `arca` auto-deployed; all verified live.

## Commits pushed (main)
- 8df83ef  arca landing: warm-black Personal Life OS rewrite (three shifts, commitment loop scene, A2A scoped packets, honest status strip); Google sign-in carries a 15-min httpOnly profile hint
- 82f81c8  web app core loop: identity onboarding, capture → extraction → Commitment Graph (drag scope) → bounded run → evidence → feedback rails → A2A prototype; drizzle 0006 + tables
- 7f696b1  provider chain Claude→OpenAI→demo, idempotent schema bootstrap (CREATE IF NOT EXISTS on first request), approval semantics fixes, "ARCA it?" bar on graph page
- c52b797  drag scope reads a ref (no stale closure on fast drags)
- 5f40f0b  Google sign-in lands in the web app by default; device-link step only with `flow=device`
- (rebased over the unrelated "First Contact" PR #9 that another session merged; builds clean)

## Live URLs
- Landing: https://thezonebio.com/arca (proxied) = https://arca-the-zone-bio.vercel.app/arca
- Sign-in: https://arca-the-zone-bio.vercel.app/arca/onboarding  (all landing CTAs point here; "Continue with Google")
- App home: https://arca-the-zone-bio.vercel.app/arca/app  (session gate → redirects to sign-in when not logged in)
- Identity onboarding: /arca/app/onboarding · Capture: /arca/app/capture · Graph: /arca/app/c/[id] · A2A: /arca/app/a2a
- Logout: /api/arca/auth/logout
- Note: the session cookie lives on the arca origin; thezonebio.com/arca/app → redirects into the arca origin sign-in, which is the intended path.

## Done (Live, verified on production)
- New landing: hero "약속을, 현실이 될 때까지." with breathing Commitment Graph (sequential node lighting, path growth, evidence lock), three-shift section (From fragmented tasks / generic intelligence / prompted assistance → living model / your definition of good / proactive orchestration) each with an explanatory SVG motion, 7-beat auto-playing core-loop scene (감지 → ARCA it? → drag scope → execute pulse → boundary question → evidence lock → consent/quality rails into Taste Model), A2A scoped-packet scene with both gates + both locks, Company Brain AX = Work Shell section, honest Live / Prototype / Coming next strip, "arca 해놔." final CTA. Metadata updated. Desktop 1440 and 375px mobile: no horizontal overflow, Pretendard loads, CTAs resolve to the arca-origin sign-in.
- Google login (scope now `openid email profile`; name/picture only ever used as a *candidate*, held in a 15-min httpOnly cookie, never stored unless confirmed). Real round trip tested: account chooser → consent → /arca/app.
- Identity onboarding WOW ("Don't introduce yourself. Let ARCA try."): /api/arca/identity/candidates checks Google hint + Gravatar (SHA-256 public profile JSON) + email-domain public homepage (skipped for free-mail). For me@thezonebio.com it produced "Minsung Park · THE ZONE BIO · CEO, Founder" at 80% with both sources linked. ≥70% → "혹시 이분이 맞나요?", below → asks openly. Confirm-only write to `profiles`; "아니에요 · 직접 수정" path; profile delete; guardrail strip; after confirmation ARCA proposes a first action grounded only in confirmed context (never fabricates missed appointments).
- Capture: paste or in-browser MediaRecorder → existing /api/arca/transcribe (whisper) → /api/arca/commitments/extract (Claude structured output; OpenAI fallback; demo fallback clearly labelled "Demo 추출 (모델 키 없음)"). Production used Claude. Sample transcript produced 2 commitments with 7-node paths (약속 → 단가 조정 판단! → 초안 → 승인 → 발송 → 대기 → 결과).
- "ARCA it?" per commitment (capture page and graph page) → accepted.
- Commitment Graph: achievement-map SVG, diamond nodes, sequential lighting, path growth, drag from start node to any node → orange dashed region "이번 위임 범위 · N단계" persisted (scopeStart/scopeEnd) → status authorized.
- Bounded run (/run): start node locks with the transcript quote as evidence; risky/decision nodes stop with a boundary question (승인 / 수정 / 거절); `draft` nodes really generate the artifact with the LLM (production draft used the confirmed profile as sender); `approve` gate; out-of-scope nodes stop with "이 단계는 위임 범위 밖입니다. ARCA가 이어서 진행할까요?" and a yes extends the scope; `send` blocks honestly ("발송은 Gmail 연결 후 · Coming next") until the user pastes evidence; `wait`/`outcome` block until external evidence. Evidence locks show a lock glyph (not a checkmark); Evidence trail panel; Promise Packet status ladder detected → … → verified.
- Feedback: two separate rails (consent: 맡길 것/묻고 할 것/하지 말 것 · quality: 내 기준에 맞았다/수정 필요) stored as separate `feedback_events`; Taste Model panel shows counts per rail, labelled Prototype (recorded, not yet applied).
- Connected sources panel: Google Live · web capture Live · Mac beta Live (+ device-link link) · Gmail / Calendar / Slack = Coming next.
- Empty / loading / error states on home, capture, graph, onboarding; 401 → sign-in redirect (client + server layout gate); refresh-safe (all state in Postgres).

## Prototype (labelled in UI)
- External evidence is pasted by the user (no Gmail/Calendar/payment adapters yet).
- Taste Model records feedback but does not yet change proposals/question frequency.
- /arca/app/a2a: 6-step simulation of ARCA↔ARCA scoped coordination (request/authority/evidence packets only, both gates must open, both completion nodes lock). Explicitly labelled "Prototype — 시뮬레이션 · 상대 사용자 없음"; cites PR #6 as demo-only.

## Coming next (labelled in UI)
- Gmail send + reply evidence, Google Calendar acceptance evidence, Slack, payment/delivery adapters.
- Applying the taste model to future proposals.
- ARCA Core hardware.

## Production end-to-end transcript (2026-09-21, me@thezonebio.com)
1. https://thezonebio.com/arca → CTA → arca-origin /arca/onboarding → Continue with Google → account chooser → consent (name, picture, email) → landed /arca/app. ✅
2. /arca/app/onboarding → candidate "Minsung Park · THE ZONE BIO · CEO, Founder" 80% (Gravatar + thezonebio.com) → 맞아요 → profile saved → first proposal card "Minsung Park, THE ZONE BIO의 약속부터 잡아볼게요." ✅
3. /arca/app/capture → 샘플 대화 넣기 → 약속 감지하기 → provider `claude` → summary + 2 commitments (샘플 3종 택배 / 금요일까지 견적서 300개). ✅
4. ARCA it? on the 견적서 commitment → /arca/app/c/fb10781c-… → 7 nodes drawn. ✅
5. Drag 약속 → 수령 확인 대기 → "범위: 견적서 발송 약속 → 수령 확인 대기 · 6단계". ✅
6. 범위 안 실행 → #1 locked (transcript evidence) → #2 판단 asks "단가를 5% 이내에서 조정하시겠습니까?" ✅ → consent feedback 묻고 할 것 → 승인 → #3 초안 generated (real Claude draft, sender = confirmed profile) → quality 내 기준에 맞았다 → 승인 → #4 승인 auto-done → #5 발송 blocked "Gmail 발송 · Coming next" ✅
7. Pasted 링크 evidence → #5 locked → #6 대기 blocked → pasted 상대 회신 → locked → #7 결과 outside scope → "범위 밖 · ARCA가 먼저 묻습니다" → 승인 (scope extends) → blocked for evidence → pasted 수락 회신 → **verified** ("보냈어요"가 아니라 "끝났어요"). Final: 잠긴 노드 4/7 · 외부 증거 3. ✅
8. Home shows the verified commitment under "Verified · 외부 증거로 닫힘"; Taste Model consent 1 / quality 1. ✅
Same loop was also run end-to-end locally (port 4198, OpenAI provider) before deploy.

## DB
- Tables created: `profiles`, `commitments`, `commitment_nodes`, `feedback_events`, enum `commitment_status` (drizzle/0006_commitment_loop.sql + meta snapshot). Applied to the local `.env.local` Neon DB by hand and to the **production DB automatically via idempotent bootstrap** (lib/commitments/schema-bootstrap.ts) — confirmed by production API returning 200 and rows (2 commitments, 2 feedback events for the founder's user).
- Note: the dev-machine `.env.local` DATABASE_URL is a different Neon DB (0 users) from production; do not mistake it for prod.

## Screenshots (tmp/)
webapp_prod_landing_desktop.jpg, webapp_prod_landing_loop.jpg, webapp_prod_landing_mobile.jpg (375px), webapp_prod_signin.jpg, webapp_prod_onboarding.jpg, webapp_prod_graph_scoped.jpg, webapp_prod_draft.jpg, webapp_prod_verified.jpg, webapp_prod_home.jpg; local: webapp_landing_*.jpg, webapp_onboarding_*.jpg, webapp_capture_detected.jpg, webapp_graph_*.jpg, webapp_a2a.jpg, webapp_home.jpg.

## Blockers / caveats
- Local `.env.local` Anthropic key has no credit ("credit balance is too low") → local runs fell back to OpenAI (works). Production Anthropic key works.
- `usage_events` inserts fail on the local dev DB (enum lacks the traction kinds) — logged, non-fatal, production unaffected.
- Old `/arca/onboarding` device-link + plan + First Contact "moment" steps still exist for the Mac app hand-off (`?step=device`/`flow=device`); web users now bypass them and go to /arca/app/onboarding.
- In-browser recording → whisper path is wired to the existing metered /api/arca/transcribe but was not exercised with real audio in this run (no mic in automation); the paste path is what the demo should use.
- Old local `next start` servers on ports 4193/4196/4197/4198 could not be killed from the sandbox (Operation not permitted); harmless.
- Local dev DB contains 6 junk "Demo 추출" commitments from testing; production has only the 2 real ones.
