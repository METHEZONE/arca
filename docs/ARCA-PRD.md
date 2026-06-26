# ARCA — Product Requirements Document (v1)

> **Authoritative reference for "what ARCA is."**
> Brand/worldview lives in the canon (`THE ZONE/Brand/ARCA-WORLDVIEW-CANON.md`, aliases `[[ARCA 세계관]]`).
> This PRD locks the **v1 product**. When the two disagree on product scope, this PRD wins.

## Metadata
- Source: Deep Interview (11 rounds, Socratic + ambiguity-gated)
- Final ambiguity: **~3%** (threshold 20%, source: default)
- Type: greenfield (existing macOS prototype treated as demo, not the spec)
- Status: **PASSED** — all open questions resolved
- Generated: 2026-06-24 / 2026-06-25

---

## 1. One-liner
**ARCA is a flow-state guardian** — an AI companion that keeps knowledge workers *in the ZONE* by intelligently triaging incoming interruptions: handling what it can on your behalf, deferring the rest, then reporting back what it did.

## 2. Why it exists (the job)
Communication overhead now eats more time than actual work. But if you stop communicating, **you become the bottleneck**. ARCA absorbs the communication/coordination layer so you can stay in deep focus *without* becoming the bottleneck.

## 3. Positioning / category
- ❌ NOT a **second brain** (storage). ❌ NOT a **second-self clone** (talks like you).
- ✅ Category = **delegation / handoff** — ARCA *handles* so you stay in the ZONE.
- Hero framing = **Flow-State Guardian** ("ARCA keeps you in the ZONE").
- Main verb = **"arca it"** = complete delegation, zero residue.

## 4. Target user
Knowledge / office workers whose day is fragmented by meetings + work chat.
Initial validation cohort: Hyundai employees (conservative org) + individuals. v1 lives in the **work context**.

## 5. Core loop (the mechanism = the product's heart)
0. **Enter the ZONE** — the user explicitly starts a deep-work session with one button (the ritual). ARCA begins guarding. *(Manual trigger, not auto-detected, in v1.)*
1. **Judge** each incoming item (message / notification / request / meeting) using your context + memory.
2. **Handle** low-stakes items autonomously ("arca it") — simple acknowledgements, FYIs, scheduling. **Ceiling: no hidden impersonation in v1.** Any Slack message ARCA sends during THE ZONE mode must be transparently signed as ARCA-assisted.
3. **Defer / batch** what it can't — kept out of your awareness until you leave the ZONE.
4. **Escalate** items that genuinely need your call as **game-like quick choices** (visual-novel / 미연시 UX) — surfaced in the report, resolved in a few taps.
5. **Expedition report** when you leave the ZONE (see §7.5).

## 5.5. The Expedition Report (trust surface — core demo)
Vibe: **like Pikmin returning from an expedition** — ARCA went out, did things, and comes back to show what it gathered.
- **Top (subtle):** ZONE time recovered + interruptions absorbed — a quiet stat line. *(This is the core ZONE metric.)*
- **Main body:** a **narrative recap** — "here's what happened while you were away." Story + insight, not a raw log.
- **Then:** **pending decisions** as game-choice cards (the items escalated from step 4).

## 6. v1 scope (the wedge)
- **Channels:** **Slack** (live work-chat triage) + **Meetings/calls** (capture → action).
- **KakaoTalk** = the aspirational channel, **deferred** (closed API).
- **Platform:** desktop-first (deep-work context; aligns with existing macOS prototype). *[assumption — confirm]*

## 7. The demo (proof of the experience)
1. **Deep-work guardian (CORE):** during a focus session ARCA autonomously handles things; when the session ends, the user receives a **post-session report**.
2. **Game-choice decisions (CORE):** items needing the user's call appear as **visual-novel-style quick choices** — tap, tap, done.
3. **Meeting hardware (SUPPORTING / theatrical prop):** an ARCA device sits in a meeting; afterward it auto-executes doable action items, contacts the right people for the rest, and creates calendar events. Hardware is a **demo prop** (e.g., ESP32 cam) — **not a v1 product**.

> The first two demos are the core. Demo 3 is narrative/vision.

## 8. Key product primitives
- **"Enter the ZONE" button** — explicit manual start of a deep-work session (the ritual; brand-aligned).
- **Autonomous triage engine** — handle (low-stakes) / defer / escalate, per item.
- **Slack auto-reply signature** — when THE ZONE mode is on, ARCA may send low-risk Slack replies on the user's behalf, but every autonomous reply carries a visible notice such as `- sent by Min's ARCA` or `- Min's ARCA, on THE ZONE mode`.
- **Expedition Report** — Pikmin-style return: subtle ZONE-time stat → narrative recap → pending decisions. The trust surface.
- **Game-choice decision UX** — visual-novel-style decisions, resolved in a few taps.

## 9. Constraints
- Work-context wedge only (Slack + meetings) for v1.
- Desktop-first.
- **Trust model = individual-first / bottom-up.** v1 ships to individuals who connect *their own* Slack + record *their own* meetings as a personal productivity tool. **No IT/security approval required** — deliberately sidesteps the conservative-org gatekeepers (the #1 adoption blocker in user research). Enterprise/tenant deployment is **in active design** (see §9.5) — the message to investors/orgs: *"individual today, enterprise-ready by design."*

## 9.5. Security & Trust Architecture (Hyundai-ready)
> v1 ships individual-first, but the stack is **designed for conservative enterprises from day one** so adoption can climb bottom-up → team → enterprise without a re-architecture. This is both a roadmap and an IR credibility point.

**Tiered deployment**
| Tier | Status | Model |
|------|--------|-------|
| **T1 — Individual** | v1 (now) | Personal OAuth, least-privilege (read-first) scopes, data region-pinned to Korea, ZDR with LLM providers |
| **T2 — Team / Enterprise** | in development | SSO (SAML/OIDC), SCIM provisioning, RBAC, admin console, audit logs, retention controls, PII/DLP redaction |
| **T3 — Private tenant / sovereign** | roadmap | Single-tenant VPC isolation, **BYOK** (customer-managed keys via KMS), VPC peering/PrivateLink, optional on-prem / open-weight models for max-sensitivity data |

**Cross-cutting controls**
- **LLM data handling:** **Zero Data Retention (ZDR) + no-training** enterprise agreements (Anthropic / OpenAI); PII redaction *before* model calls; sensitive tenants routable to on-prem / open-weight models. (ZDR requires negotiated enterprise agreements — not default PAYG.)
- **Encryption:** TLS 1.3 in transit, AES-256 at rest, per-tenant / BYOK keys.
- **Identity & access:** SSO (SAML/OIDC), SCIM, RBAC, least-privilege OAuth, IP allowlisting.
- **Auditability & human-in-the-loop:** immutable audit log of *every action ARCA takes on your behalf*; approval gates for high-risk outbound actions; visible ARCA signature on autonomous Slack replies; configurable retention; meeting-recording consent management.
- **Data residency:** Korea region pinning (AWS Seoul / domestic cloud) for data sovereignty.

**Compliance roadmap**
- **ISMS-P** (KISA — the credential Korean conglomerates like Hyundai require) → primary target.
- **ISO 27001 / ISO 27701** (international ISMS + privacy) + **SOC 2 Type II** (global enterprise) → in parallel.
- Note: ISMS-P + SOC 2 Type II each need ~6 months of operating evidence — start the clock early to be credible at enterprise sales time.

## 10. Non-goals (v1)
- ❌ All channels at once (broad scope was an assumption — dropped).
- ❌ KakaoTalk integration (API blocked → future).
- ❌ Hardware as a shipping product (demo prop only).
- ❌ Headlining as note-storage / second-brain archive (memory *serves* triage; it is not the hero).
- ❌ Silent "second-self" posting. ARCA may reply autonomously only when THE ZONE mode is explicitly on, the item is low-risk, and the message visibly discloses ARCA assistance.
- ❌ Enterprise / IT-approved deployment as a *v1 ship target* (v1 is individual bottom-up) — **but the enterprise security stack is in active design**, not deferred to "someday" (see §9.5).

## 11. Acceptance criteria
- [ ] During a deep-work session, ARCA handles ≥1 real incoming item end-to-end, correctly, without user intervention.
- [ ] Any autonomous Slack reply includes a visible ARCA notice (e.g. `- sent by Min's ARCA`) and is captured in the post-session audit/report.
- [ ] Sensitive categories (contracts, pricing commitments, legal, HR, conflict, unfamiliar external contacts) are escalated as choices/drafts, not auto-sent.
- [ ] At session/day end, ARCA produces a report of handled + deferred items the user trusts as accurate.
- [ ] Items needing a decision are presented as quick game-style choices resolvable in a few taps.
- [ ] The user experiences measurably less context-switching / more uninterrupted ZONE time.
- [ ] Wedge (Slack + meetings) works end-to-end; no other channel is required for the core demo.

## 12. Assumptions exposed & resolved
| Assumption | Challenge | Resolution |
|------------|-----------|------------|
| All channels needed for v1 | Contrarian: would one channel be useless? | No — a single-channel wedge is fine |
| KakaoTalk as the wedge | Reality of closed API | Deferred to future |
| Hardware is a product | What is v1's real boundary? | SW is the product; HW = demo prop |
| It's a meeting recorder (the prototype) | Hero is Shield, not Capture | Capture *serves* the guardian; hero = flow guardian |
| Broad "multichannel magic" required | Measured requirement or habit? | Habit — wedge-first, expand later |

## 13. Ontology (key entities)
| Entity | Type | Notes |
|--------|------|-------|
| ZONE | core | the protected focus state / world |
| ARCA | core | the guardian companion (arc + archive + ark) |
| Incoming Item | core | message / notification / request / meeting to triage |
| Decision Card | core | game-choice surfaced to the user |
| Report | core | post-session / daily summary of handled + deferred |
| Channel | supporting | Slack, Meetings (v1); KakaoTalk (future) |
| Hardware Prop | external / demo | ESP-cam meeting device (non-product) |

## 13.5. Plans & Packaging (Individual → Enterprise)
> Pricing below is **illustrative / to-validate** (anchor with the WTP survey results: individuals signalled ~₩5k–30k/mo). The *structure* is the point: a bottom-up PLG ladder that climbs into a conservative-org enterprise contract.

| Plan | Who | Price (illustrative) | Key includes |
|------|-----|----------------------|--------------|
| **Free** | individuals trying it | ₩0 | 1 ZONE session/day, 1 channel (Slack *or* meetings), basic Expedition Report |
| **Pro** | power individuals | ~₩12,900/mo | Unlimited sessions, Slack **+** meetings, full report + ZONE-time stats, game-choice decisions, memory |
| **Team** | small teams | ~₩19,900/seat/mo | Everything in Pro + shared admin, team focus analytics, centralized billing, shared playbooks |
| **Enterprise** | conservative orgs (Hyundai) | Custom (annual) | Everything in Team **+** the full §9.5 enterprise stack ↓ |

### Enterprise plan — what makes it "enterprise"
- **Deployment:** private single-tenant / VPC, optional sovereign-cloud or on-prem (open-weight models for max-sensitivity data).
- **Security:** BYOK (customer-managed keys), ZDR, DLP/PII redaction, Korea data residency, immutable audit export.
- **Identity & admin:** SSO (SAML/OIDC), SCIM provisioning, RBAC, org console with policy controls (recording consent, retention).
- **Compliance:** ISMS-P, ISO 27001/27701, SOC 2 Type II, DPA + security-questionnaire / procurement support.
- **Commercial:** annual contract, volume seat pricing, dedicated CSM + onboarding/training, uptime + support-response **SLA**.

### GTM motion
**Land bottom-up → expand → convert.** Individuals/teams adopt with zero IT involvement (T1/T2) → usage spreads inside the org → when org-wide demand + a security review trigger, convert to an **Enterprise** contract (T3). PLG → sales-assisted. The enterprise security stack being *already designed* is what makes the conversion credible rather than a 12-month rebuild.

## 14. Open questions (next to resolve)
- ✅ ~~Session trigger~~ → resolved: manual **"Enter the ZONE"** button (R9).
- ✅ ~~Slack action ceiling~~ → resolved: low-stakes auto + escalate rest as game-choice; no impersonation v1 (R8).
- ✅ ~~ZONE metric / report~~ → resolved: subtle ZONE-time stat + narrative recap + pending decisions, Pikmin-expedition feel (R10).
- ✅ ~~Security / permission model~~ → resolved: **individual-first / bottom-up**, no IT approval, personal-scope connections; enterprise post-v1 (R11).
- ⬜ Exact desktop platform (macOS-first assumed) + multi-agent "expedition" architecture detail.

---

## 15. Interview transcript (7 rounds)
<details><summary>Full Q&A</summary>

- **R0 Topology:** All 4 components (Capture / Memory / Delegation / Focus Shield) confirmed active.
- **R1 Goal — v1 hero:** Flow-State Guardian (Focus Shield, "keeps you in the ZONE"). Capture+Memory serve it; delegation = the how.
- **R2 Goal — mechanism:** Intelligent triage → handle-or-defer per item ("판단 후 혼합").
- **R3 Constraints — channels:** broad (work comms + OS notifications + meetings).
- **R4 Contrarian — scope:** single-channel wedge is OK; broad was an assumption.
- **R5 Constraints — the wedge:** Slack + meetings first; KakaoTalk deferred (closed API).
- **R6 Simplifier — success signal:** handles real items (#2) + accurate end-of-day report (#3); demo = deep-work→report, game-choice decisions, (supporting) meeting hardware.
- **R7 Constraints — v1 boundary:** SW is the product; hardware is a demo prop (ESP cam).

Final ambiguity: 12% (PASSED).
</details>
