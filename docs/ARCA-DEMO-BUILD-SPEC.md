# ARCA — Live Demo Build Spec (master)

> **Goal:** a real, working macOS `.dmg` that demonstrates ARCA's WOW use case end-to-end,
> built on the **`desktop/` Electron app**. Build for a live stage demo tomorrow.
> Build agents: read this whole file first. Match `desktop/src/shared/arca-types.ts` exactly.

## The WOW (what the demo proves)
ARCA is a **flow-state guardian** + **cross-source insight engine**.
1. User clicks **Enter the ZONE** → ARCA guards a focus session (companion goes "guarding").
2. User types (demo) **"매니저님들께 ___ 메일 보내줘"** → ARCA drafts + **really sends** email (SMTP). Signed `– Min's ARCA`.
3. While guarding, incoming items (email / Slack) are each **judged**: HANDLE low-stakes silently, DEFER noise, ESCALATE sensitive.
4. User clicks **Leave the ZONE** → **Expedition Report**:
   - quiet headline stat ("28 min in the ZONE · 7 handled")
   - "while you were away" narrative recap + handled list (with named judgment badges + source chips)
   - **decision cards** (game-choice, visual-novel feel) with a **pre-drafted reply** and **ARCA's recommendation pre-selected** → resolve in one tap
   - **★ Suggestions + Cross-Insights**: ARCA read Obsidian + email + Slack + transcripts and surfaced
     recommended tasks, recommended delegations, and **connections the user hadn't noticed**.

## Live vs demo data rule (CRITICAL)
The app already has a `live ↔ demo` toggle for Gmail. Mirror that everywhere:
**use real data when a connector is configured; otherwise use a rich, hand-authored demo dataset.**
The demo must look flawless with NO creds connected. Never crash on missing keys.

## Competitor steal list (apply to the report UI)
From `docs/research/competitor-dimension.md` + `competitor-bond.md` (read them). Build ORIGINAL
implementations inspired by these patterns — do not copy their code/assets:
1. **Pre-drafted reply on every decision card** (Dimension's best interaction).
2. **Three-section report IA**: Handled / Decisions(game-cards) / Suggestions+Insights+Stats.
3. **Name the judgment on screen** (HANDLE/DEFER/ESCALATE badges) — both competitors hide it; this is our clarity moat.
4. **Pre-select ARCA's recommendation** on each card.
5. **Source-origin chips** (✉ # ◆ 🎙) on every item — trust booster.
6. **One quiet emotional stat headline** — screenshot-able proof of value.
7. Avoid Dimension's failure mode: passive briefing nobody habituates to. Our antidotes = the ZONE
   ritual, the companion character, narrative recap, game-card pacing. Sharpen those.

## Architecture (on desktop/ Electron)
```
src/shared/arca-types.ts          ← data contract (DONE — single source of truth)
src/renderer/src/styles/tokens.css ← design tokens (DONE — consume these, no raw hex)

OWNED BY INTEGRATOR (do not touch):
  src/main/index.ts                ← IPC wiring, gmail-send (exists)
  src/preload/index.ts             ← bridge
  src/renderer/src/App.tsx         ← top-level wiring, ZONE button, tab routing

MODULE BOUNDARIES (each agent creates ONLY new files in its dir):
  A. src/renderer/src/components/companion/*   ← new clean animated character
  B. src/main/insight/*                        ← cross-source insight engine
  C. src/renderer/src/components/expedition/*  ← Expedition Report + decision cards UI
  D. src/main/sources/* + src/main/demo/*      ← source readers + rich demo dataset
```

## Module specs
### A — Companion character (renderer)
Replace `arubi` (spritesheet, too rough for production). Build a **clean, code-animated**
companion in **SVG + CSS** (no external art, no new deps): a soft rounded form with **expressive
eyes** that blink and react. States map to `ZonePhase` + activity:
`idle | listening | thinking | guarding | happy | reporting`. Smooth, premium, never cheesy.
Export `<Companion mood="..." size={..}/>`. Self-contained CSS using tokens.css vars.
Deliver a tiny demo harness comment showing each state.

### B — Insight engine (main)
Pure TS. Input: `{ obsidian: NoteDoc[]; emails: IncomingItem[]; slack: IncomingItem[]; transcripts: TranscriptDoc[] }`.
Output: `{ suggestions: Suggestion[]; insights: CrossInsight[] }` (types from arca-types).
Use `@anthropic-ai/sdk` (already a dep) with a strong system prompt to (a) propose recommended
tasks + delegations + followups, each grounded in real sources, and (b) find **cross-source
connections** the user likely missed (>=2 sources each). If no `ANTHROPIC_API_KEY`, return a
hand-authored fixture that tells a compelling connected story. Export `runInsightEngine(ctx, opts)`.
Define `NoteDoc`/`TranscriptDoc` minimal shapes in your own file and export them.

### C — Expedition Report UI (renderer)
The screen shown on Leave the ZONE. Implement the three-section IA + the steal list above.
Components: `<ExpeditionReport report={ExpeditionReport} onResolve={(cardId, optionId)=>..}/>`,
`<DecisionCard>`, `<HandledRow>`, `<SuggestionCard>`, `<InsightCard>`, `<SourceChip>`, `<JudgmentBadge>`.
Use tokens.css. Motion: soft staggered entrance via CSS (Pikmin-return warmth, calm not bouncy).
Drive entirely from the `ExpeditionReport` prop — no data fetching inside. Read the Dimension report
for layout/interaction inspiration; original implementation only.

### D — Sources + demo dataset (main)
- `src/main/sources/`: readers that normalize each channel into `IncomingItem[]` /
  note docs. `obsidian.ts` (read .md from a vault path), `slack.ts` (Slack token if present),
  `transcripts.ts` (read ARCA-saved memories), `gmailAdapter.ts` (wrap existing gmail-list/get).
  Each: live if configured, else empty (the demo dataset covers the gap).
- `src/main/demo/dataset.ts`: a **rich, realistic, interconnected** demo dataset — Obsidian notes,
  emails, Slack messages, transcripts — engineered so the insight engine surfaces 2-3 genuinely
  surprising cross-source connections (e.g. a transcript action item that matches an unanswered
  email that matches an Obsidian note). This dataset is what makes the demo magical. Make it about
  THE ZONE BIO / a founder's week. Korean + English mixed is fine and realistic.

## Acceptance
- `cd desktop && npm run build` succeeds; `electron-builder --mac dmg` produces a runnable .dmg.
- Enter/Leave ZONE works; Expedition Report renders from real session data.
- "send email" path really sends (SMTP) when configured; shows clearly in handled list.
- Insight engine surfaces >=2 cross-source insights + >=3 suggestions in demo mode.
- No raw hex in new CSS (tokens only); no crashes with zero creds.

## Notes
- Don't run `npm install` in parallel agents; author code only. Integrator runs install/build.
- TypeScript must compile against arca-types.ts. If a type is wrong, report it — don't diverge.
