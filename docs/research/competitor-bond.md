# Competitor Teardown: **Bond** (bondapp.io) — "Your AI Chief of Staff"

> Research date: 2026-06-26. Prepared for ARCA competitive benchmarking.
> Author note: This is the AI-EA / comms-triage product most adjacent to ARCA. Confidence on each claim is flagged. Where I could not verify (e.g., live demo video transcript, pixel-level visual specs), I say so explicitly rather than inventing.

---

## 0. Which "Bond" is this? (disambiguation)

There are several products named "Bond." The one analyzed here is the one most similar to ARCA:

- **✅ ANALYZED — Bond, "Your AI Chief of Staff."** Canonical URL: **https://www.bondapp.io/**. YC company (Spring/X25 batch), founded 2025 by Chloe Samaha (CEO), Flor Sanders (CTO), Tibo Wiels (CPO). This is an AI assistant that reads your Slack/email/calendar/docs and produces a self-managing, prioritized to-do list + daily briefing. Directly comparable to ARCA's interruption-triage + report model.
  - Sources: [bondapp.io](https://www.bondapp.io/), [YC company page](https://www.ycombinator.com/companies/bond), [YC launch](https://www.ycombinator.com/launches/Ncl-bond-ai-chief-of-staff-for-ceos-and-busy-execs), [Product Hunt](https://www.producthunt.com/products/bond-12).

- ❌ NOT this — "Bond" social-media / anti-doomscrolling app ([TechCrunch, Apr 2026](https://techcrunch.com/2026/04/21/bond-social-media-platform-ai-memories-kick-doomscrolling-habit/)).
- ❌ NOT this — "Outbond" / Bond outbound-sales campaign tool ([Product Hunt](https://www.producthunt.com/products/outbond)).
- ❌ NOT this — "BOND.AI" (financial-services / banking AI; separate Crunchbase entity).
- ❌ NOT this — "Bond Global" (bond-global.com, enterprise services).

**Important nuance — the product pivoted.** Earlier 2025 materials (YC page, hiretop coverage) describe Bond as an **ops-visibility tool** with an AI named **"Donna"**, a **"Presidential Brief,"** a **Live Dashboard**, and a **"Pattern Radar"** (KPIs, churn alerts, team capacity). The **current site (June 2026)** has repositioned hard toward **"the AI to-do list that does itself"** — a personal, Slack-native task/triage layer for the individual executive. ARCA should benchmark against the **current** positioning, but the older "Donna + dashboard" framing is useful context for where Bond came from and what they de-emphasized.
- Old framing: [YC company page](https://www.ycombinator.com/companies/bond), [hiretop](https://hiretop.com/startup-updates/ai-chief-of-staff-for-ceos-bond-donna/).
- New framing: [bondapp.io](https://www.bondapp.io/), [Product Hunt](https://www.producthunt.com/products/bond-12).

---

## 1. What it is

- **One-liner (current, verbatim):** "The AI Chief of Staff every founder deserves. Bond connects to your tools, learns how your company works, and tells you your highest leverage move." ([bondapp.io](https://www.bondapp.io/))
- **Product Hunt tagline (verbatim):** "The AI to-do list that does itself." ([Product Hunt](https://www.producthunt.com/products/bond-12))
- **Category:** AI Chief of Staff / personal AI EA / self-managing task + triage layer. Explicitly **not a dashboard** — they say "You don't need another dashboard. You need someone who connects the dots." ([about page](https://www.bondapp.io/about))
- **Who it's for:** Founders, CEOs, C-suite execs, "high performers" — people who can't afford (or don't want) a $150k/yr human Chief of Staff. Enterprise tier extends to "your whole C-suite" + seat-sharing with EAs. ([bondapp.io](https://www.bondapp.io/), [pricing](https://www.bondapp.io/pricing))
- **Core job:** Ingest everything scattered across the work stack (Slack, email, calendar, docs, PM tools), build a "company brain," and each morning hand the user a single ranked to-do list of their highest-leverage moves — while quietly handling or delegating the low-value busywork.

**ARCA relevance:** Same core thesis ("information is scattered, the human is overwhelmed, an AI should triage and surface only what needs you"). The key difference: **Bond is a productivity/leverage layer for execs (output = prioritized to-do list + briefing); ARCA is a focus-protection layer for ICs/knowledge workers (output = guarded deep-work session + post-session expedition report).** Bond optimizes "what's my highest-leverage move"; ARCA optimizes "protect my flow and tell me what happened while I was gone."

---

## 2. Core features (exhaustive, with how each works)

All from [bondapp.io](https://www.bondapp.io/), [pricing](https://www.bondapp.io/pricing), [YC launch](https://www.ycombinator.com/launches/Ncl-bond-ai-chief-of-staff-for-ceos-and-busy-execs), [Product Hunt](https://www.producthunt.com/products/bond-12), [hiretop](https://hiretop.com/startup-updates/ai-chief-of-staff-for-ceos-bond-donna/).

1. **Task capture & consolidation (the "commitment tracker").**
   - Reads every Slack message, email, meeting, and doc. Automatically extracts commitments: "tracks every 'I'll get back to you,' every pending reply, every open thread." Surfaces them so nothing falls through. This is the heart of the product.

2. **Smart prioritization / ranking (P0–P3).**
   - "It doesn't just list tasks. It ranks them. The most important thing is always at the top." Uses the company-context model to assign priority levels (P0–P3). Framed as "Tells you what to do next. Not another to-do list."

3. **Daily Briefing / "Presidential Brief."**
   - Each morning Bond delivers a **one-page snapshot via Slack or email**: "what moved, who's blocked, and your top 3 priorities." Positioned as a replacement for status-update meetings and all-hands. (In the old framing this was the "Presidential Brief.")

4. **Task automation (autonomous handling).**
   - "Recurring, low-value tasks? Bond handles them." Bond does the grunt work autonomously to free founder focus. Marketing line: "Bond handled the grunt work. Your to-do list is ready when you are." ([about](https://www.bondapp.io/about))

5. **Delegation to team members.**
   - From Product Hunt: Bond can "delegate tasks to team members." Items in the briefing are tagged **"Needs you"** vs. **"Delegated to [person]"** — i.e., Bond can route work outward, not just inward.

6. **Team visibility / accountability ("what your team owes you").**
   - "See everything your team owes you. At a glance." Tracks pending items owed by team members with overdue indicators; politely follows up on commitments so the exec doesn't have to chase.

7. **Drafting & action execution.**
   - On request Bond will "prepare you for your next meeting, draft a follow-up, send an email, create action items, identify blockers, surface risks, or delegate." So it both *finds* work and *does* work (drafting/sending email, creating action items). ([Product Hunt](https://www.producthunt.com/products/bond-12))

8. **"Company brain" / contextual model.**
   - "Reads all your tools and builds your company's brain — your goals, your team, who owns what, and what's slipping." Built with LLMs + vector search indexing across platforms. Every surfaced fact carries **source citations** ("Gmail / Slack / Calendar / Notion") so the exec can trust it. ([YC](https://www.ycombinator.com/companies/bond), [hiretop](https://hiretop.com/startup-updates/ai-chief-of-staff-for-ceos-bond-donna/))

9. **"Ask Bond/Donna Anything" (conversational query).**
   - ChatGPT-style natural-language interface over the company data: "is X blocked, who owns Y, what's the pipeline status" — replacing "Slack ping-pong or a 30-minute catch-up call." (Heavily emphasized in old framing; still present as the conversational layer.)

10. **Pattern Radar (proactive anomaly alerts) — older framing, possibly de-emphasized.**
    - Proactive monitoring that pings on "stalled initiatives, employee overload, customer churn spikes, and anything else that might fly under the radar." ([hiretop](https://hiretop.com/startup-updates/ai-chief-of-staff-for-ceos-bond-donna/))

11. **Live Dashboard (older framing, now de-emphasized).**
    - KPIs, real-time team capacity, project status with owners, deadlines. The new site explicitly distances from "another dashboard," so treat this as legacy/secondary. ([YC](https://www.ycombinator.com/companies/bond))

**Tech stack signal (from Product Hunt "technologies used"):** FastAPI, Next.js, Cursor. Works "across your stack via **MCP**" (Model Context Protocol) — i.e., MCP is their integration substrate. "API (Coming soon)." ([Product Hunt](https://www.producthunt.com/products/bond-12), [pricing](https://www.bondapp.io/pricing))

---

## 3. Primary user flow / "wow" moment + onboarding

**Onboarding (verified from copy; exact screens not pixel-verified):**
1. Connect your stack: Slack, Gmail, Google Calendar, Notion, Jira/Asana/Linear, etc. (OAuth-style tool connection). White-glove onboarding for pilot/enterprise cohorts. ([how-it-works coverage](https://hiretop.com/startup-updates/ai-chief-of-staff-for-ceos-bond-donna/))
2. Bond scans connected apps to identify projects, deadlines, owners, dependencies, and blockers, and builds the "company brain."
3. Bond installs into Slack — **"Lives in Slack," "no new app to learn."** ([pricing](https://www.bondapp.io/pricing))

**The recurring "wow" moment (the daily loop):**
- Each **morning**, the user opens Slack (or email) to a **one-page Daily Briefing**: status line ("you're all caught up"), top-3 priorities, and a ranked to-do list with **P0–P3 labels** and **source chips** (Gmail/Slack/Calendar/Notion). Each item is tagged **"Needs you"** (escalated to the human) or **"Delegated to [person]"** (Bond already routed it). The user resolves the "Needs you" items right inside Slack.
- The emotional payoff Bond sells: **"Bond handled the grunt work. Your to-do list is ready when you are."** The wow is waking up to a pre-triaged, pre-ranked, partially-already-handled day instead of an overflowing inbox. ([bondapp.io](https://www.bondapp.io/), [about](https://www.bondapp.io/about))

> ⚠️ I could **not** retrieve the YC demo video transcript (YouTube returned only navigation chrome; X/Twitter returned 402). So the precise on-screen choreography of the demo is unverified. The flow above is reconstructed from site/PH/coverage copy, which is consistent across sources.

**ARCA contrast:** Bond's "wow" is the **morning briefing** (calendar-anchored, daily, push). ARCA's "wow" is the **Expedition Report on leaving the ZONE** (session-anchored, on-demand, pull). Bond's report is a *flat ranked list*; ARCA's is a *narrative recap + game-choice decision cards*. ARCA's surface is more delightful and more decision-oriented; Bond's is more frequent and habit-forming.

---

## 4. UX & interaction patterns

- **Surface = Slack-native** (plus email for the briefing). No standalone heavy app; the briefing and "Ask Bond" both live where the exec already is. This is a deliberate "meet you where you work / zero new app" bet. ([pricing](https://www.bondapp.io/pricing))
- **Decision/approval model = two-tier autonomy:**
  - **Autonomous tier:** recurring, low-value tasks → Bond just handles them ("does itself"). Delegation to teammates can happen automatically (item shows as "Delegated to X").
  - **Human-in-the-loop tier:** strategic / sensitive items are flagged **"Needs you"** and surfaced for the human to action. So it's HANDLE-vs-ESCALATE, surfaced as labels in the briefing. (There is **no visible third "DEFER" state** like ARCA's — Bond's model is essentially HANDLE / ESCALATE; deferral is implicit via priority ranking P2/P3.)
- **Trust mechanic = source citations on everything.** Every surfaced item links back to its origin (Gmail/Slack/Notion/Calendar). This is their answer to "can I trust the AI's summary?" Strong, copyable pattern. ([YC](https://www.ycombinator.com/companies/bond))
- **Notification model:** proactive **morning push** (the briefing) + **real-time pings** on blockers/risks/wins (Pattern Radar lineage) + **on-demand pull** (Ask Bond). Mixed push/pull.
- **Digest/report surface:** the Daily Briefing IS the report surface — one page, top-3, ranked list, caught-up status. It is **recurring and time-based**, not event/session-based.
- **Follow-up automation:** Bond "politely follows up" on commitments owed to the user — an outbound nudging behavior, not just inbound triage.

---

## 5. Design language (what I could verify, and what I couldn't)

> ⚠️ Honesty flag: I could not pull the live screenshots (huntscreens returned 403; X returned 402; YouTube blocked). The following is inferred from copy, layout descriptions, and the brand's stated posture. Treat color/typography specifics as **low confidence** and verify by visiting the site directly before recreating.

- **Overall posture:** Modern, minimal, "executive premium" SaaS. Clarity over decoration. Anti-dashboard, anti-clutter — the whole pitch is *reducing* visual noise, so the aesthetic is restrained. ([about](https://www.bondapp.io/about))
- **Layout:** Briefing presented as a **single one-page card/list**: status headline → top-3 priorities → ranked items with **priority pills (P0–P3)** and **small source-logo chips** (Gmail/Slack/Calendar/Notion). "Needs you" vs "Delegated to [name]" rendered as tags/badges per row.
- **Character/mascot:** The current bondapp.io brand is **professional/minimal with no visible mascot**. Historically the AI persona was named **"Donna"** (a human-secretary persona, evoking *Suits*' Donna Paulsen — the legendary chief-of-staff/EA archetype). The current site downplays the named persona in favor of "Bond." ⚠️ Unverified whether "Donna" persona is still surfaced in-product.
- **Tone of voice:** Confident, slightly provocative, anti-corporate-theater. Verbatim founder line: "we're killing corporate theater… if you're the type that likes to talk about work instead of getting it done, yes you should be afraid of AI." ([Chloe Samaha / X](https://x.com/bondwithchloe/status/1928142811095867827)) Marketing copy is punchy and benefit-led ("Now every founder can afford one").
- **Typography/color:** Not verifiable from text; presents as clean sans-serif, high-whitespace, likely monochrome + single accent. **Verify directly.**

**ARCA contrast (and opportunity):** Bond's design is *deliberately undramatic* (premium-minimal, no character). ARCA's whole differentiator is the **opposite**: a cute menu-bar character "face," Pikmin-expedition warmth, visual-novel decision cards, motion/narrative. ARCA owns the emotional/delightful lane that Bond explicitly vacated. Don't copy Bond's restraint — copy its *information structure* (ranked rows + source chips + needs-you/delegated tags) and wrap it in ARCA's character/narrative skin.

---

## 6. Platform & tech

- **Platform:** Web app + **Slack-native** delivery (briefing + Ask Bond live in Slack) + **email** for briefing. No mention of a native desktop or mobile app — Slack/email IS the client. (Contrast: ARCA is a native macOS menu-bar app.) ([pricing](https://www.bondapp.io/pricing), [app login](https://app.bondapp.io/login))
- **Integrations (named across sources):** Slack, Gmail/email, Google Calendar, Notion, Jira, Asana, Linear, GitHub, Salesforce. Connectivity substrate = **MCP** ("works across your stack via MCP"). Public **API "coming soon."** ([pricing](https://www.bondapp.io/pricing), [YC](https://www.ycombinator.com/companies/bond))
- **Auth/permissions model:** OAuth-style tool connections. Stated data posture: **"Your data is encrypted, never sold, never used to train AI, and you can delete it whenever you want"** (30-day deletion). Enterprise: **SOC 2 Type II, SSO, SCIM, audit logs, on-prem option**, "forward-deployed AE." Older materials cite **on-premise / data-stays-in-client-infra** and SOC 2 via Probo. ([bondapp.io](https://www.bondapp.io/), [pricing](https://www.bondapp.io/pricing), [YC launch](https://www.ycombinator.com/launches/Ncl-bond-ai-chief-of-staff-for-ceos-and-busy-execs))
- **AI tech:** LLMs + vector search for cross-platform indexing/retrieval; MCP for tool actions. ([hiretop](https://hiretop.com/startup-updates/ai-chief-of-staff-for-ceos-bond-donna/))

---

## 7. Pricing & packaging

From [bondapp.io/pricing](https://www.bondapp.io/pricing):

| Tier | Price | Terms | What's included |
|---|---|---|---|
| **Human Chief of Staff** (anchor) | **$150,000/yr** | — | Anchoring comparison only — "hire a human" |
| **Standard / Individual** | **$99 /seat/month** | Billed annually. **50% beta discount** for early customers, **locked for the first year**. | "Saves 10+ hrs/week," reads every Slack/email/meeting/doc, builds company brain, master to-do list every morning, lives in Slack, works across stack via MCP, API (coming soon) |
| **Enterprise** | **Custom** ("locked for life on your account") | — | Whole-C-suite, custom company brain, seat-sharing with EAs/Chiefs of Staff, SOC 2 Type II / SSO / SCIM / audit logs, dedicated onboarding + forward-deployed AE, custom integrations + on-prem, SLA + priority support |

- **No free tier / no self-serve free trial** visible. Beta-gated; "Talk to a founder" Calendly CTA. The $150k human-CoS anchor is the core pricing-psychology move ("Every founder needs a Chief of Staff. Now every founder can afford one").
- **Funding context:** **$3M seed** announced **Dec 7, 2025**, led by **Fellows Fund** (per founder's LinkedIn; some aggregators list CoreNest). YC X25. ([Signalbase](https://www.trysignalbase.com/news/funding/bond-ai-chief-of-staff-for-ceos-secures-3-million-seed-funding), [Chloe Samaha LinkedIn](https://www.linkedin.com/posts/chloesamaha_today-were-announcing-bond-ycx25s-3m-activity-7402384118543568897-hXKs))

---

## 8. Positioning & messaging

- **Master headline:** "The AI Chief of Staff every founder deserves." ([bondapp.io](https://www.bondapp.io/))
- **Category-defining line:** "The AI to-do list that does itself." ([Product Hunt](https://www.producthunt.com/products/bond-12))
- **Anti-dashboard wedge:** "You don't need another dashboard. You need someone who connects the dots… knows what's urgent, what's noise, and what needs you right now." ([about](https://www.bondapp.io/about))
- **Affordability/value frame:** "$150,000/yr human CoS" vs "$99/mo" → "Now every founder can afford one." Quantified promise: **"saves 10+ hours a week."**
- **Emotional payoff:** "Bond handled the grunt work. Your to-do list is ready when you are."
- **Provocative brand stance:** "killing corporate theater" — anti-meeting, anti-status-update, pro-output. ([X](https://x.com/bondwithchloe/status/1928142811095867827))
- **Credibility/trust framing:** source citations on every fact + "never used to train AI" + SOC 2.
- **Target persona:** the overwhelmed founder/CEO (and by extension their EA/CoS via seat-sharing). Built on a claimed **"2,000+ executive interviews."** ([YC launch](https://www.ycombinator.com/launches/Ncl-bond-ai-chief-of-staff-for-ceos-and-busy-execs))

---

## 9. Strengths

1. **Sharp, ownable category line** ("the to-do list that does itself") + a brutal price anchor ($150k human → $99). Easy to remember, easy to justify.
2. **Slack-native = near-zero adoption friction.** No new app, no behavior change; shows up where execs already live. Huge for activation.
3. **Source-citation trust mechanic** — every surfaced item is traceable. Directly addresses the #1 objection to AI summaries ("can I trust it?").
4. **Two-tier autonomy that's legible** ("Needs you" vs "Delegated") — users instantly understand what the AI did vs what they must do.
5. **Outbound follow-up + team-accountability** ("what your team owes you," polite auto-follow-ups) — it acts *on the org*, not just on your inbox. More leverage than a passive summarizer.
6. **Strong wedge narrative** built on 2,000 interviews + YC + $3M seed + clear ICP (founders/CEOs). Credible GTM.
7. **MCP-based integration substrate** — future-proof, lets them add tools fast and act (not just read).

---

## 10. Weaknesses / gaps (where ARCA can win)

1. **No focus/flow protection.** Bond optimizes *output and leverage*, but does nothing to **guard attention in real time**. It's a once-a-morning batch product; it doesn't stand between you and the firehose during deep work. **ARCA's "Enter the ZONE" real-time guardianship is a category Bond doesn't touch.**
2. **Emotionally flat / no delight.** Deliberately minimal, no character, no narrative, list-based UX. **ARCA's character face + Pikmin expedition + visual-novel decision cards own the delight/affinity lane.** People don't *love* a ranked list; they can love a companion.
3. **Daily batch ≠ moment-of-need.** Briefing is time-based (every morning). It doesn't map to the natural unit of a knowledge worker's day (a focus session). **ARCA's session-anchored Expedition Report fires exactly when the user resurfaces** — better timing, better story.
4. **HANDLE/ESCALATE only — no explicit DEFER.** Bond collapses everything into priority ranking; there's no clean "I looked at this and chose to hold it for you" state. **ARCA's explicit HANDLE / DEFER / ESCALATE triad is more transparent and more trustworthy.**
5. **Founder/CEO-only ICP + $99/seat + beta-gated, no free tier.** Excludes the vast IC knowledge-worker market and has high adoption cost. **ARCA can win the much larger "any deep-focus knowledge worker" segment** and with a lighter desktop install + freemium.
6. **Slack/email-bound; no native desktop presence.** No ambient menu-bar companion, no OS-level "I'm protecting you now" surface. **ARCA's always-present macOS menu-bar character is a persistent brand+utility surface Bond lacks.**
7. **Decision UX is a list, not a flow.** Resolving items = reading rows in Slack. **ARCA's tap-through game-choice cards (with ARCA's recommendation per card) is a faster, more satisfying decision loop.**
8. **Persona instability / pivot risk.** Public materials whipsaw between "Donna + dashboard + Pattern Radar" and "to-do list that does itself." Some surfaces still say "dashboard," contradicting the "you don't need a dashboard" message. ARCA should keep one crisp story.

---

## 11. ★ STEAL LIST (prioritized, with WHY)

### Quick wins — buildable for a demo TOMORROW
1. **Source chips on every surfaced item.** Each decision card / report line shows a small origin badge (Slack / Gmail / Calendar / Meeting). **Why:** instant trust + looks credible in a demo; trivial to render. Bond's single best low-cost trust mechanic. ARCA should put it on every Expedition Report card.
2. **"Needs you" vs "Handled / Deferred" tags + a top-of-report status line.** Open the Expedition Report with a one-liner like "While you were in the ZONE, ARCA handled 7, deferred 3, and 2 need you." **Why:** Bond's "you're all caught up" + Needs-you/Delegated tagging is the exact emotional payoff; it frames the AI as having *already done work*. Maps perfectly onto ARCA's HANDLE/DEFER/ESCALATE.
3. **Priority ranking on the decision cards (P0–P3 / urgency sort).** Put the must-decide card first. **Why:** Bond's "the most important thing is always at the top" — reduces decision fatigue, makes the few-taps resolution feel guided.
4. **The $X human-equivalent price anchor in pitch/landing.** Borrow the "$150k human vs $X" framing for ARCA (e.g., cost of a lost flow-state hour, or "a human gatekeeper costs $…"). **Why:** dirt-cheap to add to a slide; instantly reframes value.
5. **ARCA's recommendation pre-baked on each card** (Bond ranks + suggests next move). You already plan this — make it explicit and prominent: each game-choice card leads with "ARCA recommends: Defer to tomorrow." **Why:** mirrors Bond's "tells you what to do next," and turns triage into one-tap confirmation.

### Medium-term (next few sprints)
6. **Outbound auto-follow-up on commitments.** Bond "politely follows up" on things owed to you. ARCA could, post-ZONE, auto-draft the nudge for deferred/owed items. **Why:** moves ARCA from passive triage → active leverage; strong retention hook.
7. **A lightweight daily/recurring digest in addition to the session report.** Bond's morning briefing is a powerful *habit* surface. ARCA could add an optional "start of day" briefing to complement the per-session Expedition Report. **Why:** captures the daily-habit muscle Bond relies on, without abandoning the session model.
8. **"Ask ARCA Anything" conversational layer over the captured context.** Bond's natural-language query over the company brain is sticky. **Why:** turns the captured ZONE-context into an interrogable knowledge surface; high perceived intelligence.
9. **MCP as the integration substrate.** Bond standardized on MCP to add tools + *act* fast. **Why:** future-proofs ARCA's Slack/email/calendar/meeting connectors and lets ARCA *take actions*, not just read.
10. **Team-accountability view ("what others owe you").** Bond surfaces inbound commitments from teammates. **Why:** natural ARCA expansion once single-player works; expands from "guard my focus" to "guard my obligations."

### Things to deliberately NOT copy (differentiate instead)
- **Don't** go minimal/character-less. ARCA's character + narrative + game-choice UX is the moat Bond left wide open.
- **Don't** make the report a flat Slack list. Keep the tap-through visual-novel decision cards — faster and more lovable.
- **Don't** restrict to founders/CEOs at $99/seat. ARCA's wedge is the much larger IC knowledge-worker who wants *flow protection*, a problem Bond doesn't solve at all.

---

## Source list
- Bond homepage — https://www.bondapp.io/
- Bond pricing — https://www.bondapp.io/pricing
- Bond about — https://www.bondapp.io/about
- Bond app login — https://app.bondapp.io/login
- YC company page — https://www.ycombinator.com/companies/bond
- YC launch post — https://www.ycombinator.com/launches/Ncl-bond-ai-chief-of-staff-for-ceos-and-busy-execs
- Product Hunt — https://www.producthunt.com/products/bond-12
- Hiretop "Meet Donna" coverage — https://hiretop.com/startup-updates/ai-chief-of-staff-for-ceos-bond-donna/
- Signalbase $3M seed — https://www.trysignalbase.com/news/funding/bond-ai-chief-of-staff-for-ceos-secures-3-million-seed-funding
- Chloe Samaha LinkedIn (seed announcement) — https://www.linkedin.com/posts/chloesamaha_today-were-announcing-bond-ycx25s-3m-activity-7402384118543568897-hXKs
- Chloe Samaha / X — https://x.com/bondwithchloe and https://x.com/bondwithchloe/status/1928142811095867827
- BOND HQ / X — https://x.com/bondhq_
- Crunchbase — https://www.crunchbase.com/organization/bond-37a1

### Verification gaps (could not confirm directly)
- **Live demo video transcript** (YouTube `CWE6AkaOn9M`) — blocked; flow reconstructed from copy.
- **Pixel-level visual design** (color, type, screenshots) — huntscreens 403, X 402; design section is inferred, flagged low-confidence. Recommend visiting bondapp.io directly to confirm before recreating UI.
- **Whether the "Donna" persona + dashboard/Pattern Radar still ship** in the current product (materials conflict due to the pivot).
