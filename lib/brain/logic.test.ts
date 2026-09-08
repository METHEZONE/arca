import assert from "node:assert/strict";
import { test } from "node:test";

import { CAPS, isDue, renderBufferLine, sanitizeWriteMemory } from "./logic.ts";

test("isDue: not due below both thresholds", () => {
  assert.equal(isDue(5, new Date("2026-09-08T00:00:00Z"), new Date("2026-09-08T04:00:00Z")), false);
  assert.equal(isDue(0, null, new Date("2026-09-08T00:00:00Z")), false);
});

test("isDue: due once pending count hits 10", () => {
  assert.equal(isDue(10, null, new Date("2026-09-08T00:00:00Z")), true);
  assert.equal(isDue(11, new Date("2026-09-08T00:00:00Z"), new Date("2026-09-08T00:00:00Z")), true);
});

test("isDue: due once the oldest pending entry is stale 8h+", () => {
  const oldest = new Date("2026-09-08T00:00:00Z");
  assert.equal(isDue(1, oldest, new Date("2026-09-08T07:59:00Z")), false);
  assert.equal(isDue(1, oldest, new Date("2026-09-08T08:00:00Z")), true);
  assert.equal(isDue(3, oldest, new Date("2026-09-08T09:00:00Z")), true);
});

test("sanitizeWriteMemory: drops a page with an invalid slug", () => {
  const result = sanitizeWriteMemory(
    {
      pages: [
        { slug: "Not Valid Slug!", title: "bad", summary: "s", body: "b", edges: [] },
        { slug: "people/kim-cs", title: "good", summary: "s", body: "b", edges: [] },
      ],
      views: {},
      delete_slugs: [],
    },
    [],
  );
  assert.equal(result.pages.length, 1);
  assert.equal(result.pages[0].slug, "people/kim-cs");
  assert.equal(result.errors.length, 1);
});

test("sanitizeWriteMemory: caps body/summary/view lengths", () => {
  const longBody = "b".repeat(CAPS.body + 500);
  const longSummary = "s".repeat(CAPS.summary + 50);
  const longEssentials = "e".repeat(CAPS.essentials + 100);
  const longRecent = "r".repeat(CAPS.recent + 100);

  const result = sanitizeWriteMemory(
    {
      pages: [{ slug: "objects/notion", title: "t", summary: longSummary, body: longBody, edges: [] }],
      views: { essentials: longEssentials, recent: longRecent },
      delete_slugs: [],
    },
    [],
  );

  assert.equal(result.pages[0].body.length, CAPS.body);
  assert.equal(result.pages[0].summary.length, CAPS.summary);
  assert.equal(result.views.essentials?.length, CAPS.essentials);
  assert.equal(result.views.recent?.length, CAPS.recent);
  assert.equal(result.views.threads, undefined); // omitted key stays omitted
});

test("sanitizeWriteMemory: edges filtered to known slugs only", () => {
  const result = sanitizeWriteMemory(
    {
      pages: [
        {
          slug: "arcs/2026-09-08-beta",
          title: "t",
          summary: "s",
          body: "b",
          edges: ["people/kim-cs", "no-such-page", "objects/notion", "arcs/2026-09-08-beta"],
        },
      ],
      views: {},
      delete_slugs: [],
    },
    ["people/kim-cs"], // objects/notion doesn't exist yet, but IS written this same batch below
  );
  // objects/notion wasn't written in this batch and isn't pre-existing, so it's dropped;
  // no-such-page is dropped; self-edge is dropped; people/kim-cs (pre-existing) survives.
  assert.deepEqual(result.pages[0].edges, ["people/kim-cs"]);
});

test("sanitizeWriteMemory: edges may point at pages written in the same batch", () => {
  const result = sanitizeWriteMemory(
    {
      pages: [
        { slug: "arcs/2026-09-08-beta", title: "t", summary: "s", body: "b", edges: ["objects/notion"] },
        { slug: "objects/notion", title: "t2", summary: "s2", body: "b2", edges: [] },
      ],
      views: {},
      delete_slugs: [],
    },
    [],
  );
  assert.deepEqual(result.pages[0].edges, ["objects/notion"]);
});

test("sanitizeWriteMemory: delete_slugs filtered to slugs that actually exist", () => {
  const result = sanitizeWriteMemory(
    { pages: [], views: {}, delete_slugs: ["people/kim-cs", "never-existed"] },
    ["people/kim-cs"],
  );
  assert.deepEqual(result.deleteSlugs, ["people/kim-cs"]);
});

test("renderBufferLine: formats as '- [YYYY-MM-DD HH:mm · source] text' in Asia/Seoul", () => {
  // 2026-09-08T05:30:00Z is 14:30 in Asia/Seoul (UTC+9).
  const line = renderBufferLine({
    text: "회의 시작",
    source: "meeting",
    createdAt: new Date("2026-09-08T05:30:00Z"),
  });
  assert.equal(line, "- [2026-09-08 14:30 · meeting] 회의 시작");
});

test("renderBufferLine: accepts an ISO string createdAt", () => {
  const line = renderBufferLine({
    text: "hello",
    source: "chat",
    createdAt: "2026-09-08T00:00:00Z",
  });
  assert.equal(line, "- [2026-09-08 09:00 · chat] hello");
});
