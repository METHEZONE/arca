# YC Application Draft — ARCA (THE ZONE BIO)

_초안 2026-07-08 · 답변은 영어(제출용), 주석·TODO는 한국어. 숫자는 캡스톤 Final Report에서 검증된 것만 사용._
_제출 전 체크: 배치 지원 마감일, 최신 waitlist/MRR 숫자 갱신, 데모 영상 링크._

---

## Company

**Company name:** ARCA

**Describe what your company does in 50 characters or less.**

> An AI companion that finishes delegated work.

(49 chars. 대안: "Your second self. Say 'arca it.' It gets done." — 47 chars, 보이스 강함)

**Company URL:** https://thezonebio.com/arca

**Demo video (≤3 min):** TODO — The Loop 데모 (아래 §Video script). 화면녹화 + 실시간, 편집 최소.

**What is your company going to make? Please describe your product and what it does or will do.**

> ARCA is an AI companion that takes complete delegations. You say "arca it — wrap up this meeting," and ARCA does the whole job: transcribes the recording with speaker separation, extracts the decisions and action items, drafts the follow-up messages, files everything into your knowledge tools (Notion, Obsidian, Slack), and reports back when it's done. Not a chatbot you babysit — you hand off the task and leave.
>
> Under it is a memory layer: every meeting, conversation, and decision becomes a searchable memory. Ask "what did we decide about pricing?" and ARCA answers from your actual meetings, grounded with verbatim quotes — then drafts the follow-ups that decision still needs.
>
> Today ARCA runs as a web product with a live delegation loop (⌘K → "arca it" → watch it recall, reason, draft, file, and report in real time) plus meeting capture via browser and a hardware ingest path. The wedge is meetings + team chat for knowledge workers whose day is fragmented across both. The endgame is the delegation verb: whatever lands on you, you arca it and stay in flow.

---

## Founders

**Technical founder?** Yes — solo founder, wrote the product end to end (Next.js/TypeScript web app, streaming delegation engine, STT/diarization pipeline, LLM analysis with structured outputs, connector integrations, ESP32 hardware ingest).

**Founder: Minsung Park (박민성)**
- Founder, THE ZONE BIO. Yonsei University (TAP4001 venture capstone — ARCA was built and validated through it).
- me@thezonebio.com · +82 10-9942-7360 · X @methezone · LinkedIn /in/minsungparkzone · GitHub METHEZONE
- TODO: 학력/경력 한 줄 정리, 배치 중 풀타임 커밋 명시.

**How long have the founders known one another and how did you meet?** N/A (solo).
(TODO: 코파운더 영입 계획 질문 대비 — "open to a cofounder I've worked with; not blocking on it" 톤 권장.)

---

## Progress

**How far along are you?**

> The product is live and self-serve at thezonebio.com/arca. The full loop works today: record or upload a meeting → diarized transcript → grounded summary, decisions, action plan → auto-filed to Obsidian/Notion/Slack. The "arca it" command bar streams a delegation end to end (recall → reason → draft → file → report) and files its own completion report back into your second brain. It runs in zero-key demo mode out of the box and activates live layers per API key.
>
> Built in [N]-week sprints while validating: 40 user interviews, a waitlist of [UPDATE — 50+ at last count], and a live 10-minute demo pitch at Hyundai ZER01NE's demo day. Pre-revenue; founding-member pricing ($19/mo locked for life, first 1,000) opens with the next launch.

TODO: waitlist/인터뷰/MRR 숫자 제출 직전 갱신. ZER01NE 결과(후속 미팅 등) 있으면 추가.

**Tech stack:** Next.js 16 / React 19 / TypeScript, Anthropic Claude (structured outputs) + OpenAI fallback for analysis, OpenAI diarized STT + ElevenLabs Scribe fallback, SSE streaming delegation engine, file-based second brain with connector sync (Obsidian/Notion/Slack), ESP32-S3 hardware ingest path, Vercel.

**Are people using your product?** TODO — waitlist + 초기 사용자 수, 본인+팀 dogfooding("this application's follow-ups were drafted by ARCA" 류 한 줄이 강력).

**Revenue?** Not yet. Founding tier $19/mo (locked for life) + Teams $99/seat; opens at launch.

---

## Idea

**Why did you pick this idea to work on? Do you have domain expertise in this area? How do you know people need what you're making?**

> Microsoft's Work Trend Index says knowledge workers now spend 57% of their day communicating and only 43% creating. I lived it: every meeting and Slack thread generated invisible homework — remember, summarize, follow up, file — and none of the "AI notetakers" actually did that work; they just stacked more notes to read.
>
> I ran 40 interviews with knowledge workers fragmented across meetings and team chat. The recurring line was some version of "we lose every decision within a week." People don't want another archive. They want the loop closed — the follow-up sent, the decision filed where the team works, the open items resurfaced at the right time.
>
> I built ARCA through Yonsei's venture capstone, validated the positioning through user research (SW-first; hardware is a roadmap accessory, not the product), and pitched it live at Hyundai ZER01NE's demo day. I've been dogfooding it daily — including for this application.

**What's new about what you're making? What substitutes do people resort to because it doesn't exist yet (or they don't know about it)?**

> Every competitor in this space stops at notes. Otter, Fireflies, Granola, Plaud, Clova Note — they transcribe and summarize, then leave you a pile of documents and "action items" nobody executes. The substitute today is a human doing the residue: reading the summary, writing the follow-ups, updating Notion, pinging the owner.
>
> ARCA's unit of value is a completed delegation, not a note. "arca it" means the whole job — recall, reason, draft, file, report back — with zero residue left in your head. The second difference is memory: delegations run on top of everything ARCA has ever heard, so "draft follow-ups for everyone I met this week" is answerable. The third is form: ARCA is a companion with a face and a name, not a dashboard — it's designed to be something you hand things to, which is a habit (a verb), not a feature.

**Who are your competitors? What do you understand about your business that they don't?**

> AI meeting notetakers (Otter, Fireflies, Granola, Plaud, tl;dv; Tiro/Clova Note in Korea) and general assistants (ChatGPT, Copilot). The notetakers understand capture; the assistants understand chat. Neither owns *completion*: the notetakers stack summaries and the assistants wait for you to prompt them step by step.
>
> What we understand: the productivity impact isn't in the transcript, it's in closing the request→retrieve→respond loop. Transcription and diarization are commodities (that's why we treat providers as swappable). The defensible layer is the accumulated personal memory + the delegation habit — once "arca it" is your reflex for anything that lands on you, switching costs are your entire externalized memory.

**How do or will you make money? How much could you make?**

> Subscription: Free (1 companion, 50 delegations/mo) → $19/mo Second Self (founding price locked for life, first 1,000) → $99/seat ZONE for Teams (characterized team agents, shared memory). Gross margin ~85% at current inference costs (diarized STT ~$0.22/hr + Claude analysis).
>
> The AI meeting-assistant market is ~$3.5B growing to ~$21.5B by 2033 (25.8% CAGR). Our Y3 target is ~120K paying users ≈ $21.6M ARR (~0.34% of US SAM) — before the Teams tier and the agent marketplace expand ARPU.

**Category / vertical:** B2B productivity / AI assistant (bottom-up PLG: individual today, enterprise-ready by design — SSO/SCIM, audit logs, region pinning on the roadmap).

---

## Equity / Legal

- TODO: 법인 상태 (THE ZONE BIO 한국 법인? 미국 플립 계획?) — YC 표준은 Delaware C-corp 플립. 지분 100% Min? 정리 필요.
- Fundraising: not raised / TODO 사실대로.

---

## Curious

**What convinced you to apply to YC?**

> ARCA is a verb-and-habit business — it wins by compounding users' memory and reflexes, which means speed and distribution decide it. YC is the fastest environment for both, and the companies I've studied for our playbook (demo-led growth into YC) all say the same thing: apply with a working loop and real pull. We have the loop; we're building the pull in public.

**How did you hear about YC?** TODO.

---

## 1-minute founder video — script

> Hi, I'm Min, founder of ARCA. Knowledge workers spend more than half their day on communication — and every meeting leaves homework: summarize, follow up, file, remember. AI notetakers don't do that work. They just give you more to read.
>
> ARCA is an AI companion you delegate to completely. Watch — [화면] — I say "arca it — wrap up this meeting." ARCA recalls the meeting, pulls the decisions, drafts the follow-ups, files everything to Notion and Slack, and reports back. Done in under a minute. I never left my work.
>
> Everything ARCA hears becomes memory, so I can ask "what did we decide about pricing?" and get the answer with receipts — from my own meetings.
>
> I built this solo through 40 interviews and a live demo day with Hyundai. The product is live, the founding tier is open, and "arca it" is becoming a verb on my team. I want YC to help make it everyone's reflex. Thanks.

(리허설 기준 55–60초. 첫 3초에 문제, 15초 안에 데모 진입.)

## Demo plan (what a YC partner clicks)

1. thezonebio.com/arca — 랜딩 30초: worldview + pricing.
2. "Try the live demo" → 제품 대시보드: showcase 메모리가 이미 살아있음 (빈 화면 절대 금지 — seeded).
3. ⌘K → "what did we decide about pricing?" → 루프 스트리밍 → 리포트 → 피드에 파일링되는 것까지.
4. (선택) 마이크로 30초 녹음 → 메모리 생성되는 실물 루프.

## 제출 전 최종 체크리스트
- [ ] waitlist·인터뷰·사용자 숫자 최신화
- [ ] 데모 영상 촬영·업로드 (The Loop, 3분 이하)
- [ ] 파운더 영상 (위 스크립트, 1분)
- [ ] 법인/지분 답변 확정
- [ ] 데모 계정/URL이 신선한 showcase 상태인지 확인 (`ARCA_SHOWCASE` on)
