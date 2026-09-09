# Traction Metrics (usage_events) Implementation Plan

> **STATUS 2026-09-10 06:00 — Tasks 1–7 DONE, on main.** Migration 0004 applied to Supabase (enum 11 values, `usage_events.owner`). Prod smoke: `POST /api/brain/events` → `{accepted:1,skipped:1}`, `GET /api/brain/metrics` 200, `/arca/metrics` 200. Swift: BrainClientTests 6/6, macOS + iOS builds succeeded; **real-device check (Task 7 Step 7) still pending** — first approval on a TestFlight/Mac build must show `closedLoops` +1. Task 8 (deck wiring) waits for data.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the IR-Day traction slide (S7) provable from the server — closed loops, delegation approval rate by day, WAU, D1/D3/D7 — with a live dashboard, by extending the existing `usage_events` table rather than building a new telemetry system.

**Architecture:** Add event kinds + an `owner` column to `usage_events` (drizzle migration), a batch ingest route `POST /api/brain/events` that reuses `lib/arca/usage.ts record()` and Brain's `resolveOwner`, a pure aggregation module `lib/brain/metrics.ts` (unit-tested with `node --test`) behind `GET /api/brain/metrics`, and a one-page dashboard at `/arca/metrics`. On the client, `BrainClient.track(kind)` queues events in `AccountDefaults` and flushes them in batches; five Swift call sites emit the events.

**Tech Stack:** Next.js 16 route handlers, drizzle-orm 0.45 + postgres.js, Supabase Postgres (Seoul), Node 24 `node:test`, Swift 6 (ArcaVoiceKit package, Swift Testing).

**Spec:** `intent/arca-zer01ne-fund3-narrative.spec.md` §2.4 (design), §1 R6·R7·R8 (requirements), §5 (verification). Intent: `intent/arca-zer01ne-fund3-narrative.intent.md`.

## Global Constraints

- No new table, no new auth: `usage_events` + `x-arca-token` / device / session via `lib/brain/owner.ts:resolveOwner` (spec N3).
- Event kinds (exact strings): `app_open`, `meeting_captured`, `proposal_shown`, `proposal_approved`, `proposal_rejected`, `task_tossed`, `loop_closed`, `auto_executed`. Existing kinds `chat`, `transcribe`, `delegate` are untouched.
- Telemetry must never break the request or the app: server `record()` already swallows DB errors; Swift `track` is fire-and-forget and offline-tolerant.
- Metrics endpoint is founder-only: owner must equal env `BRAIN_METRICS_OWNER` (default `email:me@thezonebio.com`).
- `arca-cloud-swift` **has landed** on `origin/main` (= `45e24c5`, confirmed by session arca-d3 on 2026-09-10 05:30). Branch off that. Re-grep every Swift line number below before editing; they were taken at `24781e6`.
- BrainClient already sends `x-arca-token` **and** `x-arca-device`; `resolveOwner` order on main is session > linked device (`user:`) > invite (`email:`) > unlinked device (`device:`). Reuse it unchanged so `usage_events.owner` matches `memory_entries.owner`.
- Never read or write `memory_entries` from this work — arca-d3 is running consolidation in 60-entry batches; touching `consolidated_at` would corrupt it.
- Branch: `fund3-metrics` off `origin/main`. Commit after every task. Run `npm run typecheck && npm run lint && npm run test:brain` before each commit.
- Migrations: `npx drizzle-kit generate` then `npm run db:migrate` with the **session pooler (5432)** URL (`docs/ARCA-BRAIN.md` line 11; the runtime `DATABASE_URL` in Vercel is the 6543 transaction pooler — swap the port for the migrate step only). Check `package.json` on main for `db:migrate`; if absent, `npx drizzle-kit migrate` is equivalent.

---

### Task 1: Schema — new kinds + `owner` column + migration

**Files:**
- Modify: `lib/db/schema.ts:69` (enum), `lib/db/schema.ts:72-96` (table)
- Modify: `lib/arca/usage.ts:19-35, 58-70`
- Create (generated): `drizzle/0004_<name>.sql`, `drizzle/meta/0004_snapshot.json`, `drizzle/meta/_journal.json` entry

**Interfaces:**
- Produces: `usageKindEnum` with 11 values; `usageEvents.owner: text | null`; `record(event)` accepting `owner?: string` and the new `UsageKind` union.

- [ ] **Step 1: Extend the enum and table** in `lib/db/schema.ts`:

```ts
export const usageKindEnum = pgEnum("usage_kind", [
  "chat",
  "transcribe",
  "delegate",
  // Traction events (IR Day 2026-09-21). Emitted by the apps through
  // POST /api/brain/events; aggregated by lib/brain/metrics.ts.
  "app_open",
  "meeting_captured",
  "proposal_shown",
  "proposal_approved",
  "proposal_rejected",
  "task_tossed",
  "loop_closed",
  "auto_executed",
]);
```

and inside `usageEvents` columns, after `organizationId`:

```ts
    /** ARCA Brain owner (`user:` / `device:` / `email:`), the same scope
     *  memory rows use — so traction can be cut per person even before a
     *  device is linked to an account. */
    owner: text("owner"),
```

and add to the index list:

```ts
    index("usage_events_owner_at_idx").on(table.owner, table.at),
```

- [ ] **Step 2: Extend `record()`** in `lib/arca/usage.ts`:

```ts
export type UsageKind =
  | "chat" | "transcribe" | "delegate"
  | "app_open" | "meeting_captured" | "proposal_shown" | "proposal_approved"
  | "proposal_rejected" | "task_tossed" | "loop_closed" | "auto_executed";

export const TRACTION_KINDS: ReadonlySet<UsageKind> = new Set<UsageKind>([
  "app_open", "meeting_captured", "proposal_shown", "proposal_approved",
  "proposal_rejected", "task_tossed", "loop_closed", "auto_executed",
]);
```

add `owner?: string;` to `UsageEvent` (after `organizationId`), and `owner: full.owner,` to the `.values({...})` insert.

- [ ] **Step 3: Generate the migration** (no DB needed):

```bash
npx drizzle-kit generate --name traction_events
cat drizzle/0004_traction_events.sql
```

Expected SQL contains `ALTER TYPE "public"."usage_kind" ADD VALUE 'app_open';` (×8), `ALTER TABLE "usage_events" ADD COLUMN "owner" text;`, `CREATE INDEX "usage_events_owner_at_idx" …`.

- [ ] **Step 4: Apply to Supabase**

```bash
vercel env pull .env.local --environment=production
set -a; source .env.local; set +a
npx drizzle-kit migrate
```

Expected: `migrations applied successfully`. If the pooler rejects the enum change, `export DATABASE_URL="${DATABASE_URL/:6543\//:5432\/}"` and rerun.

- [ ] **Step 5: Typecheck + commit**

```bash
npm run typecheck && git add lib/db/schema.ts lib/arca/usage.ts drizzle && git commit -m "usage_events: traction kinds + owner column (IR Day metrics)"
```

### Task 2: Pure aggregation `lib/brain/metrics.ts` (TDD)

**Files:**
- Create: `lib/brain/metrics.ts`
- Create: `lib/brain/metrics.test.ts`
- Modify: `package.json:11` — `"test:brain": "node --experimental-strip-types --test lib/brain/logic.test.ts lib/brain/metrics.test.ts"`

**Interfaces:**
- Produces:

```ts
export interface EventRow { owner: string; kind: string; at: Date }
export interface DayRow { day: string; proposals: number; approved: number; rejected: number; autoExecuted: number; approvalRate: number | null }
export interface Metrics {
  since: string; until: string;
  users: number; installs: number; wau: number; closedLoops: number; meetings: number;
  byDay: DayRow[];
  perOwnerApproval: Array<{ owner: string; days: Array<{ day: string; approvalRate: number | null; n: number }> }>;
  retention: { d1: number | null; d3: number | null; d7: number | null };
}
export function aggregate(rows: EventRow[], now: Date, since: Date): Metrics
```

- [ ] **Step 1: Write the failing tests** (`lib/brain/metrics.test.ts`):

```ts
import assert from "node:assert/strict";
import { test } from "node:test";

import { aggregate, type EventRow } from "./metrics.ts";

const d = (s: string) => new Date(s);
const ev = (owner: string, kind: string, at: string): EventRow => ({ owner, kind, at: d(at) });
const NOW = d("2026-09-19T12:00:00Z");
const SINCE = d("2026-09-10T00:00:00Z");

test("counts users, closed loops, meetings, WAU", () => {
  const m = aggregate(
    [
      ev("email:a", "app_open", "2026-09-11T01:00:00Z"),
      ev("email:a", "meeting_captured", "2026-09-11T02:00:00Z"),
      ev("email:a", "loop_closed", "2026-09-11T03:00:00Z"),
      ev("email:b", "app_open", "2026-09-01T01:00:00Z"), // before window, still a user
      ev("email:b", "app_open", "2026-09-18T01:00:00Z"),
    ],
    NOW,
    SINCE,
  );
  assert.equal(m.users, 2);
  assert.equal(m.installs, 1); // first event inside window: only a
  assert.equal(m.wau, 1); // app_open within 7d of NOW: only b
  assert.equal(m.closedLoops, 1);
  assert.equal(m.meetings, 1);
});

test("approval rate by day uses approved/(approved+rejected), null when no decisions", () => {
  const m = aggregate(
    [
      ev("email:a", "proposal_shown", "2026-09-12T01:00:00Z"),
      ev("email:a", "proposal_shown", "2026-09-12T01:10:00Z"),
      ev("email:a", "proposal_approved", "2026-09-12T01:20:00Z"),
      ev("email:a", "proposal_rejected", "2026-09-12T01:30:00Z"),
      ev("email:a", "auto_executed", "2026-09-12T01:40:00Z"),
      ev("email:a", "proposal_shown", "2026-09-13T01:00:00Z"),
    ],
    NOW,
    SINCE,
  );
  const d12 = m.byDay.find((r) => r.day === "2026-09-12")!;
  assert.equal(d12.proposals, 2);
  assert.equal(d12.approved, 1);
  assert.equal(d12.rejected, 1);
  assert.equal(d12.autoExecuted, 1);
  assert.equal(d12.approvalRate, 0.5);
  const d13 = m.byDay.find((r) => r.day === "2026-09-13")!;
  assert.equal(d13.approvalRate, null);
});

test("retention: share of owners who reopened on/after day N", () => {
  const m = aggregate(
    [
      ev("email:a", "app_open", "2026-09-10T01:00:00Z"),
      ev("email:a", "app_open", "2026-09-11T01:00:00Z"), // D1 yes
      ev("email:a", "app_open", "2026-09-17T01:00:00Z"), // D7 yes
      ev("email:b", "app_open", "2026-09-10T01:00:00Z"), // never again
      ev("email:c", "app_open", "2026-09-18T01:00:00Z"), // too young for D3/D7 → excluded from denominator
    ],
    NOW,
    SINCE,
  );
  assert.equal(m.retention.d1, 0.5); // a yes, b no (c excluded: NOW-first < 1d? no, c is 1d old → included → 1/3)
  assert.equal(m.retention.d7, 0.5); // a yes, b no, c excluded
});

test("empty input yields zeros and nulls, never NaN", () => {
  const m = aggregate([], NOW, SINCE);
  assert.equal(m.users, 0);
  assert.deepEqual(m.byDay, []);
  assert.equal(m.retention.d1, null);
});
```

Note on the D1 assertion: owner `c` first opened 2026-09-18T01:00Z, `NOW` is 2026-09-19T12:00Z → 1.46 days old → **eligible** for D1 and did not reopen → D1 = 1/3. Fix the expected value to `1 / 3` before running; the comment above documents the reasoning. D7 excludes `c` (younger than 7 days) → 1/2.

- [ ] **Step 2: Run to verify failure**

```bash
node --experimental-strip-types --test lib/brain/metrics.test.ts
```
Expected: FAIL — `Cannot find module './metrics.ts'`.

- [ ] **Step 3: Implement `lib/brain/metrics.ts`**

```ts
// Pure aggregation over usage_events rows for the IR-Day traction slide.
// No DB access here so it unit-tests with node:test; the route hands in rows.

export interface EventRow { owner: string; kind: string; at: Date }
export interface DayRow {
  day: string; proposals: number; approved: number; rejected: number; autoExecuted: number;
  approvalRate: number | null;
}
export interface Metrics {
  since: string; until: string;
  users: number; installs: number; wau: number; closedLoops: number; meetings: number;
  byDay: DayRow[];
  perOwnerApproval: Array<{ owner: string; days: Array<{ day: string; approvalRate: number | null; n: number }> }>;
  retention: { d1: number | null; d3: number | null; d7: number | null };
}

const DAY_MS = 86_400_000;
const dayKey = (d: Date) => d.toISOString().slice(0, 10);
const rate = (a: number, r: number) => (a + r === 0 ? null : a / (a + r));

export function aggregate(rows: EventRow[], now: Date, since: Date): Metrics {
  const firstSeen = new Map<string, Date>();
  const firstOpen = new Map<string, Date>();
  const opens = new Map<string, Date[]>();
  const byDay = new Map<string, DayRow>();
  const perOwnerDay = new Map<string, Map<string, { a: number; r: number }>>();
  let closedLoops = 0;
  let meetings = 0;

  for (const e of rows) {
    const f = firstSeen.get(e.owner);
    if (!f || e.at < f) firstSeen.set(e.owner, e.at);
    if (e.kind === "app_open") {
      const fo = firstOpen.get(e.owner);
      if (!fo || e.at < fo) firstOpen.set(e.owner, e.at);
      (opens.get(e.owner) ?? opens.set(e.owner, []).get(e.owner)!).push(e.at);
    }
    if (e.kind === "loop_closed") closedLoops++;
    if (e.kind === "meeting_captured") meetings++;
    if (e.at < since) continue;
    const k = dayKey(e.at);
    const row = byDay.get(k) ?? { day: k, proposals: 0, approved: 0, rejected: 0, autoExecuted: 0, approvalRate: null };
    if (e.kind === "proposal_shown") row.proposals++;
    if (e.kind === "proposal_approved") row.approved++;
    if (e.kind === "proposal_rejected") row.rejected++;
    if (e.kind === "auto_executed") row.autoExecuted++;
    byDay.set(k, row);
    if (e.kind === "proposal_approved" || e.kind === "proposal_rejected") {
      const od = perOwnerDay.get(e.owner) ?? perOwnerDay.set(e.owner, new Map()).get(e.owner)!;
      const c = od.get(k) ?? { a: 0, r: 0 };
      if (e.kind === "proposal_approved") c.a++; else c.r++;
      od.set(k, c);
    }
  }

  const days = [...byDay.values()].sort((x, y) => x.day.localeCompare(y.day));
  for (const r of days) r.approvalRate = rate(r.approved, r.rejected);

  const wauCutoff = new Date(now.getTime() - 7 * DAY_MS);
  let wau = 0;
  for (const list of opens.values()) if (list.some((t) => t >= wauCutoff)) wau++;

  let installs = 0;
  for (const f of firstSeen.values()) if (f >= since) installs++;

  const retentionAt = (n: number): number | null => {
    let eligible = 0, kept = 0;
    for (const [owner, fo] of firstOpen) {
      if (now.getTime() - fo.getTime() < n * DAY_MS) continue;
      eligible++;
      const target = fo.getTime() + n * DAY_MS;
      if ((opens.get(owner) ?? []).some((t) => t.getTime() >= target)) kept++;
    }
    return eligible === 0 ? null : kept / eligible;
  };

  const perOwnerApproval = [...perOwnerDay.entries()].map(([owner, od]) => ({
    owner,
    days: [...od.entries()].sort((x, y) => x[0].localeCompare(y[0]))
      .map(([day, c]) => ({ day, approvalRate: rate(c.a, c.r), n: c.a + c.r })),
  }));

  return {
    since: since.toISOString(), until: now.toISOString(),
    users: firstSeen.size, installs, wau, closedLoops, meetings,
    byDay: days, perOwnerApproval,
    retention: { d1: retentionAt(1), d3: retentionAt(3), d7: retentionAt(7) },
  };
}
```

- [ ] **Step 4: Run tests** — `node --experimental-strip-types --test lib/brain/metrics.test.ts` → all PASS (after fixing the D1 expectation to `1/3`). Then `npm run test:brain` (both files) → PASS.
- [ ] **Step 5: Commit** — `git add lib/brain/metrics.ts lib/brain/metrics.test.ts package.json && git commit -m "brain: pure traction aggregation (metrics.ts) with tests"`

### Task 3: Routes — `POST /api/brain/events`, `GET /api/brain/metrics`

**Files:**
- Create: `app/api/brain/events/route.ts`
- Create: `app/api/brain/metrics/route.ts`

**Interfaces:**
- Consumes: `resolveOwner` (`lib/brain/owner.ts`), `record`, `TRACTION_KINDS`, `UsageKind` (`lib/arca/usage.ts`), `aggregate` (`lib/brain/metrics.ts`), `db`, `usageEvents`.
- Produces: `POST /api/brain/events` body `{ events: Array<{ kind: string; at?: string; ok?: boolean }> }` → `{ accepted: number; skipped: number }`; `GET /api/brain/metrics?since=YYYY-MM-DD` → `Metrics` JSON.

- [ ] **Step 1: events route**

```ts
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { record, TRACTION_KINDS, type UsageKind } from "@/lib/arca/usage";
import { resolveOwner } from "@/lib/brain/owner";

interface EventInput { kind?: unknown; at?: unknown; ok?: unknown }

// Batch traction events from the apps. Same auth as /api/brain/remember;
// each event becomes one usage_events row scoped by Brain owner.
export async function POST(req: Request): Promise<Response> {
  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  let body: { events?: unknown };
  try {
    body = (await req.json()) as { events?: unknown };
  } catch {
    return Response.json({ error: "invalid json" }, { status: 400 });
  }
  const raw = Array.isArray(body.events) ? (body.events as EventInput[]) : [];
  if (raw.length < 1 || raw.length > 100) {
    return Response.json({ error: "events must be an array of 1 to 100 items" }, { status: 400 });
  }

  const deviceId = deviceIdFromRequest(req) ?? undefined;
  let accepted = 0;
  let skipped = 0;
  for (const e of raw) {
    const kind = typeof e.kind === "string" ? (e.kind as UsageKind) : null;
    if (!kind || !TRACTION_KINDS.has(kind)) { skipped++; continue; }
    await record({ owner, deviceId, kind, ok: e.ok !== false });
    accepted++;
  }
  return Response.json({ accepted, skipped });
}
```

Note: `record()` stamps `at` server-side; client `at` is ignored on purpose (clock skew, replay). If `deviceIdFromRequest` returns `null` rather than `undefined`, the `?? undefined` handles it.

- [ ] **Step 2: metrics route**

```ts
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { and, gte, inArray, isNotNull } from "drizzle-orm";

import { TRACTION_KINDS } from "@/lib/arca/usage";
import { aggregate } from "@/lib/brain/metrics";
import { resolveOwner } from "@/lib/brain/owner";
import { db } from "@/lib/db/client";
import { usageEvents } from "@/lib/db/schema";

const DEFAULT_SINCE = "2026-09-01";

// Founder-only read of the traction aggregate for the IR-Day dashboard.
export async function GET(req: Request): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const owner = await resolveOwner(req);
  const allowed = process.env.BRAIN_METRICS_OWNER?.trim() || "email:me@thezonebio.com";
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (owner !== allowed) return Response.json({ error: "forbidden" }, { status: 403 });

  const url = new URL(req.url);
  const sinceParam = url.searchParams.get("since") ?? DEFAULT_SINCE;
  const since = new Date(sinceParam);
  if (Number.isNaN(since.getTime())) return Response.json({ error: "invalid since" }, { status: 400 });

  const rows = await client
    .select({ owner: usageEvents.owner, kind: usageEvents.kind, at: usageEvents.at })
    .from(usageEvents)
    .where(and(isNotNull(usageEvents.owner), inArray(usageEvents.kind, [...TRACTION_KINDS]), gte(usageEvents.at, new Date(since.getTime() - 30 * 86_400_000))));

  const metrics = aggregate(
    rows.map((r) => ({ owner: r.owner as string, kind: r.kind, at: r.at })),
    new Date(),
    since,
  );
  return Response.json(metrics);
}
```

(The 30-day lookback before `since` lets `users`/retention see owners who first appeared earlier.)

- [ ] **Step 3: Smoke locally** (needs `.env.local` from Task 1 Step 4 and the invite code from `~/.arca/brain-invite.txt`):

```bash
npm run dev &
TOKEN=$(cat ~/.arca/brain-invite.txt)
curl -s -X POST localhost:4174/api/brain/events -H "x-arca-token: $TOKEN" -H 'content-type: application/json' \
  -d '{"events":[{"kind":"app_open"},{"kind":"proposal_shown"},{"kind":"proposal_approved"},{"kind":"loop_closed"},{"kind":"bogus"}]}'
# expect {"accepted":4,"skipped":1}
curl -s localhost:4174/api/brain/metrics -H "x-arca-token: $TOKEN" | head -c 400
# expect JSON with users>=1, closedLoops>=1, byDay[0].approvalRate 1
```

- [ ] **Step 4: Typecheck/lint, commit** — `npm run typecheck && npm run lint && git add app/api/brain/events app/api/brain/metrics && git commit -m "brain: /api/brain/events ingest + /api/brain/metrics aggregate"`

### Task 4: Dashboard `/arca/metrics`

**Files:**
- Create: `app/arca/metrics/page.tsx`

**Interfaces:** Consumes `GET /api/brain/metrics` (same origin) with header `x-arca-token` from `localStorage["arcaMetricsToken"]`.

- [ ] **Step 1: Page** (client component; tokens from `app/arca/arca.css`):

```tsx
"use client";

import { useEffect, useState } from "react";
import "../arca.css";

interface DayRow { day: string; proposals: number; approved: number; rejected: number; autoExecuted: number; approvalRate: number | null }
interface Metrics {
  since: string; until: string; users: number; installs: number; wau: number; closedLoops: number; meetings: number;
  byDay: DayRow[]; retention: { d1: number | null; d3: number | null; d7: number | null };
}

const pct = (v: number | null) => (v === null ? "—" : `${Math.round(v * 100)}%`);

function Line({ rows }: { rows: DayRow[] }) {
  const pts = rows.filter((r) => r.approvalRate !== null);
  if (pts.length === 0) return <p style={{ color: "var(--ter)" }}>승인/거절 데이터가 아직 없습니다.</p>;
  const w = 640, h = 180, pad = 24;
  const x = (i: number) => pad + (i * (w - 2 * pad)) / Math.max(1, pts.length - 1);
  const y = (v: number) => h - pad - v * (h - 2 * pad);
  const d = pts.map((r, i) => `${i === 0 ? "M" : "L"}${x(i)},${y(r.approvalRate as number)}`).join(" ");
  return (
    <svg viewBox={`0 0 ${w} ${h}`} width="100%" role="img" aria-label="위임 승인율 일별">
      <line x1={pad} y1={y(0)} x2={w - pad} y2={y(0)} stroke="var(--line)" />
      <line x1={pad} y1={y(1)} x2={w - pad} y2={y(1)} stroke="var(--line)" />
      <path d={d} fill="none" stroke="var(--accent)" strokeWidth={3} strokeLinecap="round" />
      {pts.map((r, i) => (
        <g key={r.day}>
          <circle cx={x(i)} cy={y(r.approvalRate as number)} r={4} fill="var(--accent)" />
          <text x={x(i)} y={h - 4} fontSize={10} textAnchor="middle" fill="var(--ter)">{r.day.slice(5)}</text>
        </g>
      ))}
    </svg>
  );
}

export default function MetricsPage() {
  const [token, setToken] = useState("");
  const [data, setData] = useState<Metrics | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => { setToken(localStorage.getItem("arcaMetricsToken") ?? ""); }, []);

  async function load() {
    setErr(null);
    localStorage.setItem("arcaMetricsToken", token);
    const res = await fetch("/api/brain/metrics", { headers: { "x-arca-token": token } });
    if (!res.ok) { setErr(`${res.status}`); setData(null); return; }
    setData((await res.json()) as Metrics);
  }

  useEffect(() => { if (token) void load(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [token]);

  return (
    <div className="arca-root" style={{ maxWidth: 900, margin: "0 auto", padding: 24 }}>
      <h1 style={{ fontSize: 24, fontWeight: 800 }}>ARCA 트랙션 <span style={{ color: "var(--ter)", fontWeight: 600 }}>live</span></h1>
      <div style={{ display: "flex", gap: 8, margin: "12px 0" }}>
        <input value={token} onChange={(e) => setToken(e.target.value)} placeholder="invite code" style={{ flex: 1, padding: 10, borderRadius: 12, border: "1px solid var(--line)" }} />
        <button onClick={load} style={{ padding: "10px 16px", borderRadius: 12, background: "var(--accent)", color: "#fff", border: 0, fontWeight: 700 }}>새로고침</button>
      </div>
      {err && <p style={{ color: "var(--accent)" }}>오류 {err}</p>}
      {data && (
        <>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(4,1fr)", gap: 12 }}>
            {[["사용자", data.users], ["주간 활성", data.wau], ["닫힌 루프", data.closedLoops], ["회의", data.meetings]].map(([k, v]) => (
              <div key={k as string} style={{ background: "var(--field)", borderRadius: 16, padding: 16 }}>
                <div style={{ fontSize: 32, fontWeight: 800 }}>{v as number}</div>
                <div style={{ color: "var(--ter)", fontSize: 13 }}>{k as string}</div>
              </div>
            ))}
          </div>
          <p style={{ color: "var(--sub)", margin: "12px 0" }}>리텐션 D1 {pct(data.retention.d1)} · D3 {pct(data.retention.d3)} · D7 {pct(data.retention.d7)} · 기준 {data.since.slice(0, 10)}</p>
          <h2 style={{ fontSize: 16, fontWeight: 700, margin: "18px 0 8px" }}>위임 승인율 · 일별</h2>
          <Line rows={data.byDay} />
        </>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Verify** — `npm run dev`, open `http://localhost:4174/arca/metrics`, paste the invite code → 4 numbers + line; `screencapture` one PNG into `deck/images/fund3/metrics-dashboard.png`.
- [ ] **Step 3: Commit** — `git add app/arca/metrics && git commit -m "arca: /arca/metrics live traction dashboard"`

### Task 5: Deploy server side

- [ ] `git fetch origin && git rebase origin/main` (resolve nothing expected — files are new except schema/usage).
- [ ] `git push origin fund3-metrics` → open PR → merge to `main` (Vercel production deploys). Message session `arca-d3` before pushing main.
- [ ] Verify prod: `curl -s https://arca-the-zone-bio.vercel.app/api/brain/metrics -H "x-arca-token: $(cat ~/.arca/brain-invite.txt)" | head -c 200` → 200 JSON.

### Task 6: Swift — `BrainClient.track` + queue (after arca-d3 merge lands)

**Files:**
- Modify: `apps/arca/Packages/ArcaVoiceKit/Sources/ArcaVoiceCore/BrainClient.swift` (append inside `enum BrainClient`)
- Test: `apps/arca/Packages/ArcaVoiceKit/Tests/ArcaVoiceKitTests/BrainClientTests.swift`

**Interfaces:**
- Produces: `BrainClient.track(_ kind: String)` (sync, enqueues + schedules flush), `BrainClient.flushEvents() async -> Int?`, `BrainClient.eventsPayload(_ kinds: [String]) -> Data?` (pure, tested), `BrainClient.pendingEventKinds() -> [String]`.

- [ ] **Step 1: Failing test** — add to `BrainClientTests`:

```swift
    @Test func eventsPayloadEncodesKinds() throws {
        let data = try #require(BrainClient.eventsPayload(["app_open", "loop_closed"]))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let events = try #require(json?["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(events[0]["kind"] as? String == "app_open")
        #expect(events[1]["kind"] as? String == "loop_closed")
    }
```

- [ ] **Step 2: Run** — `cd apps/arca/Packages/ArcaVoiceKit && swift test --filter BrainClientTests` → FAIL (`eventsPayload` undefined).
- [ ] **Step 3: Implement** (inside `enum BrainClient`, after `consolidateNow`):

```swift
    // MARK: - Traction events (POST /api/brain/events)

    static let eventQueueKey = "brainEventQueue"

    struct EventBody: Encodable { struct E: Encodable { let kind: String }; let events: [E] }

    /// Pure: the request body for a batch of event kinds (server stamps `at`).
    static func eventsPayload(_ kinds: [String]) -> Data? {
        guard !kinds.isEmpty else { return nil }
        return try? encoder.encode(EventBody(events: kinds.map { .init(kind: $0) }))
    }

    static func pendingEventKinds() -> [String] {
        guard let text = AccountDefaults.string(eventQueueKey), let data = text.data(using: .utf8) else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    private static func saveQueue(_ kinds: [String]) {
        let capped = Array(kinds.suffix(500))
        if let data = try? encoder.encode(capped), let text = String(data: data, encoding: .utf8) {
            AccountDefaults.set(text, for: eventQueueKey)
        }
    }

    /// Records one traction event. Never blocks; survives offline (queued in
    /// AccountDefaults) and no-ops when Brain isn't configured.
    public static func track(_ kind: String) {
        guard isAvailable else { return }
        saveQueue(pendingEventKinds() + [kind])
        Task.detached(priority: .utility) { await flushEvents() }
    }

    /// Sends up to 100 queued events. Returns accepted count, nil on failure
    /// (queue is kept for the next attempt).
    @discardableResult
    public static func flushEvents() async -> Int? {
        let queued = pendingEventKinds()
        guard !queued.isEmpty, var request = request("events", method: "POST") else { return nil }
        let batch = Array(queued.prefix(100))
        guard let body = eventsPayload(batch) else { return nil }
        request.httpBody = body
        struct Reply: Decodable { let accepted: Int }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? decoder.decode(Reply.self, from: data) else { return nil }
        saveQueue(Array(queued.dropFirst(batch.count)))
        return reply.accepted
    }
```

- [ ] **Step 4: Run** — `swift test --filter BrainClientTests` → PASS. `xcodebuild -project apps/arca/ARCA.xcodeproj -scheme ARCA -destination 'platform=macOS' build -quiet` → succeeds.
- [ ] **Step 5: Commit** — `git add apps/arca/Packages && git commit -m "BrainClient.track: queued traction events → /api/brain/events"`

### Task 7: Swift call sites (5)

Re-grep each anchor first; line numbers are from `24781e6`.

**Files:**
- Modify: `apps/arca/ArcaVoice/App/AppServices.swift` (`func configure(container:)`, ~line 50)
- Modify: `apps/arca/ArcaVoice/App/FinalPassRunner.swift` (`rememberFromMeeting`, after `await BrainClient.remember(` ~line 363)
- Modify: `apps/arca/ArcaVoice/Features/Ops/AmbientOps.swift` (`context.insert(ReplyProposal(` ~184; `proposal.stateRaw = "sent"` ~303; `func skip(` ~321)
- Modify: `apps/arca/ArcaVoice/Features/Tasks/TaskEngine.swift` (`task.state = .done` ×2 in `toss`, ~68 and ~78)
- Modify: `apps/arca/ArcaVoice/App/RelaySync.swift` (`if task.isTossable() { TaskEngine.shared.toss(task) }` ~288)

- [ ] **Step 1: AppServices** — last line of `configure(container:)` body (before the closing brace of the function, outside the `#if os(macOS)` blocks):

```swift
        BrainClient.track("app_open")
```

- [ ] **Step 2: FinalPassRunner** — right after the `await BrainClient.remember(...)` call in `rememberFromMeeting`:

```swift
        BrainClient.track("meeting_captured")
```

- [ ] **Step 3: AmbientOps** — after `context.insert(ReplyProposal(...))` (same `if` block):

```swift
                    BrainClient.track("proposal_shown")
```

after `proposal.sentAt = .now` in `approve`:

```swift
            BrainClient.track("proposal_approved")
            BrainClient.track("loop_closed")
```

inside `skip(_:context:)` after `proposal.stateRaw = "skipped"`:

```swift
        BrainClient.track("proposal_rejected")
```

- [ ] **Step 4: TaskEngine.toss** — after each `task.state = .done` (the `.research, .draft` branch and the macOS `.send, .broad` branch):

```swift
                    BrainClient.track("task_tossed")
                    BrainClient.track("loop_closed")
```

- [ ] **Step 5: RelaySync auto-toss** — inside `if task.isTossable() {` before `TaskEngine.shared.toss(task)`:

```swift
                        BrainClient.track("auto_executed")
```

- [ ] **Step 6: Build all targets** — `xcodebuild -project apps/arca/ARCA.xcodeproj -scheme ARCA -destination 'platform=macOS' build -quiet && xcodebuild -project apps/arca/ARCA.xcodeproj -scheme ARCA -destination 'generic/platform=iOS' build -quiet CODE_SIGNING_ALLOWED=NO`.
- [ ] **Step 7: Real check (ARCA Test app first, per `no-codex-for-arca`)** — run the Mac app with the invite code entered; approve one Slack/Gmail proposal; then `curl …/api/brain/metrics` → `closedLoops` incremented by 1 and today's `byDay` row has `approved: 1`.
- [ ] **Step 8: Commit** — `git add apps/arca/ArcaVoice && git commit -m "Emit traction events: app_open, meeting_captured, proposals, toss, auto_executed"`. Push, PR, merge; TestFlight build via the existing pipeline (`arca-testflight-pipeline`).

### Task 8: Wire into the deck

- [ ] Replace S7's blank cells in `ir/arca-fund3/index.html` with values from `/api/brain/metrics` on 9/17 and 9/21 morning; add the approval-rate SVG (export from the dashboard) as `img/approval-curve.svg`. Keep the "숫자가 작으면 기울기" line.
- [ ] Bookmark `https://arca-the-zone-bio.vercel.app/arca/metrics` for the live refresh during the pitch; offline fallback = screenshot from Task 4 Step 2.
