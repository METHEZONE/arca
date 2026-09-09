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
      ev("email:c", "app_open", "2026-09-18T01:00:00Z"), // 1.46d old at NOW: eligible for D1, excluded from D3/D7
    ],
    NOW,
    SINCE,
  );
  // a yes, b no, c eligible-and-no → 1/3
  assert.equal(m.retention.d1, 1 / 3);
  // c excluded (younger than 7d): a yes, b no → 1/2
  assert.equal(m.retention.d7, 0.5);
});

test("empty input yields zeros and nulls, never NaN", () => {
  const m = aggregate([], NOW, SINCE);
  assert.equal(m.users, 0);
  assert.deepEqual(m.byDay, []);
  assert.equal(m.retention.d1, null);
});
