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
