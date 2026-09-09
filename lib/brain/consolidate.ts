// Consolidation: buffer entries -> wiki pages + aggregate views, one forced
// tool call per owner. docs/ARCA-BRAIN.md §5.

import Anthropic from "@anthropic-ai/sdk";
import { and, asc, eq, isNull, lte, sql } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { memoryEntries, memoryPages, memoryRuns, memoryViews } from "@/lib/db/schema";
import { isDue, sanitizeWriteMemory, type WriteMemoryOutput } from "@/lib/brain/logic";
import { buildConsolidateUserMessage, CONSOLIDATE_SYSTEM_PROMPT } from "@/lib/brain/prompt";

type DbClient = NonNullable<ReturnType<typeof db>>;

// 60 entries fit one reply comfortably; 200 overflowed the output budget and
// came back as an empty tool call that was then treated as success.
const MAX_PENDING_ENTRIES = 40;
const MAX_RECENT_PAGES = 25;
const MAX_RECENT_PAGES_CHARS = 40_000;
// One owner takes 2–5 minutes; the cron function has 300s. Run a few owners
// at once and let the rest wait for the next hour rather than time out.
export const MAX_OWNERS_PER_CRON_RUN = 5;

const WRITE_MEMORY_TOOL: Anthropic.Tool = {
  name: "write_memory",
  description:
    "Rewrite ARCA's concept pages and aggregate views from the current buffer of memory entries.",
  input_schema: {
    type: "object",
    properties: {
      pages: {
        type: "array",
        description: "Pages to create or fully rewrite.",
        items: {
          type: "object",
          properties: {
            slug: { type: "string" },
            title: { type: "string" },
            summary: { type: "string" },
            body: { type: "string" },
            edges: { type: "array", items: { type: "string" } },
            origin_date: { type: "string", description: "YYYY-MM-DD, or omit if unknown" },
          },
          required: ["slug", "title", "summary", "body", "edges"],
        },
      },
      views: {
        type: "object",
        description: "Only include a key when it changed; omit to leave it as-is.",
        properties: {
          essentials: { type: "string" },
          threads: { type: "string" },
          recent: { type: "string" },
        },
      },
      delete_slugs: {
        type: "array",
        items: { type: "string" },
        description: "Existing slugs to remove.",
      },
    },
    required: ["pages", "views", "delete_slugs"],
  },
};

export interface ConsolidateResult {
  owner: string;
  entries: number;
  pagesWritten: number;
  ok: boolean;
  error?: string;
}

function model(): string {
  return process.env.ANTHROPIC_MODEL?.trim() || "claude-sonnet-5";
}

async function pendingStats(
  client: DbClient,
  owner: string,
): Promise<{ count: number; oldest: Date | null }> {
  const [row] = await client
    .select({
      count: sql<number>`count(*)`,
      oldest: sql<string | null>`min(${memoryEntries.createdAt})`,
    })
    .from(memoryEntries)
    .where(
      and(eq(memoryEntries.owner, owner), isNull(memoryEntries.consolidatedAt), isNull(memoryEntries.deletedAt)),
    );
  return { count: Number(row?.count ?? 0), oldest: row?.oldest ? new Date(row.oldest) : null };
}

/** Owners with at least one pending entry that meets the due rule, oldest
 *  pending first — so a cron run under the 20-owner cap favors whoever has
 *  waited longest. */
async function dueOwners(client: DbClient, now: Date): Promise<string[]> {
  const rows = await client
    .select({
      owner: memoryEntries.owner,
      count: sql<number>`count(*)`,
      oldest: sql<string>`min(${memoryEntries.createdAt})`,
    })
    .from(memoryEntries)
    .where(and(isNull(memoryEntries.consolidatedAt), isNull(memoryEntries.deletedAt)))
    .groupBy(memoryEntries.owner);

  return rows
    .filter((row) => isDue(Number(row.count), new Date(row.oldest), now))
    .sort((a, b) => new Date(a.oldest).getTime() - new Date(b.oldest).getTime())
    .map((row) => row.owner);
}

async function consolidateOwner(client: DbClient, anthropic: Anthropic, owner: string): Promise<ConsolidateResult> {
  const pending = await client
    .select({
      id: memoryEntries.id,
      text: memoryEntries.text,
      source: memoryEntries.source,
      createdAt: memoryEntries.createdAt,
    })
    .from(memoryEntries)
    .where(
      and(eq(memoryEntries.owner, owner), isNull(memoryEntries.consolidatedAt), isNull(memoryEntries.deletedAt)),
    )
    .orderBy(asc(memoryEntries.createdAt))
    .limit(MAX_PENDING_ENTRIES);

  if (pending.length === 0) {
    return { owner, entries: 0, pagesWritten: 0, ok: true };
  }

  const startedAt = new Date();
  // Only entries loaded into this batch are eligible to be marked
  // consolidated — anything created after this point waits for the next run.
  const cutoff = pending.reduce((max, e) => (e.createdAt > max ? e.createdAt : max), pending[0].createdAt);

  try {
    const viewByName = new Map<string, string>();
    for (const v of await client.select().from(memoryViews).where(eq(memoryViews.owner, owner))) {
      viewByName.set(v.name, v.body);
    }

    const allPages = await client
      .select({ slug: memoryPages.slug, title: memoryPages.title, summary: memoryPages.summary })
      .from(memoryPages)
      .where(eq(memoryPages.owner, owner));
    const existingSlugs = allPages.map((p) => p.slug);

    const recentPageRows = await client
      .select({ slug: memoryPages.slug, title: memoryPages.title, body: memoryPages.body })
      .from(memoryPages)
      .where(eq(memoryPages.owner, owner))
      .orderBy(sql`${memoryPages.updatedAt} desc`)
      .limit(MAX_RECENT_PAGES);

    let charBudget = MAX_RECENT_PAGES_CHARS;
    const recentPages: { slug: string; title: string; body: string }[] = [];
    for (const page of recentPageRows) {
      if (charBudget <= 0) break;
      const body = page.body.length > charBudget ? page.body.slice(0, charBudget) : page.body;
      recentPages.push({ slug: page.slug, title: page.title, body });
      charBudget -= body.length;
    }

    const userMessage = buildConsolidateUserMessage({
      views: {
        essentials: viewByName.get("essentials") ?? "",
        threads: viewByName.get("threads") ?? "",
        recent: viewByName.get("recent") ?? "",
      },
      pageIndex: allPages,
      recentPages,
      bufferEntries: pending,
      cutoff,
    });

    const response = await anthropic.messages.create({
      model: model(),
      max_tokens: 16000,
      system: CONSOLIDATE_SYSTEM_PROMPT,
      tools: [WRITE_MEMORY_TOOL],
      tool_choice: { type: "tool", name: "write_memory" },
      messages: [{ role: "user", content: userMessage }],
    });

    if (response.stop_reason === "max_tokens") {
      throw new Error("write_memory output truncated at max_tokens; batch left pending");
    }
    const toolUse = response.content.find((block) => block.type === "tool_use");
    if (!toolUse || toolUse.type !== "tool_use") {
      throw new Error("Anthropic response had no write_memory tool_use block");
    }

    const sanitized = sanitizeWriteMemory(toolUse.input as WriteMemoryOutput, existingSlugs);
    const wroteNothing = sanitized.pages.length === 0 && Object.keys(sanitized.views).length === 0;
    if (wroteNothing && pending.length >= 5) {
      // A real batch that files nothing is a failed call, not a quiet day;
      // leaving it pending is what lets the next run retry it.
      throw new Error(`model wrote no pages or views for ${pending.length} entries; batch left pending`);
    }

    for (const page of sanitized.pages) {
      await client
        .insert(memoryPages)
        .values({
          owner,
          slug: page.slug,
          title: page.title,
          summary: page.summary,
          body: page.body,
          edges: page.edges,
          originDate: page.origin_date ? new Date(page.origin_date) : null,
          updatedAt: new Date(),
        })
        .onConflictDoUpdate({
          target: [memoryPages.owner, memoryPages.slug],
          set: {
            title: page.title,
            summary: page.summary,
            body: page.body,
            edges: page.edges,
            originDate: page.origin_date ? new Date(page.origin_date) : null,
            updatedAt: new Date(),
          },
        });
    }

    for (const [name, body] of Object.entries(sanitized.views)) {
      await client
        .insert(memoryViews)
        .values({ owner, name, body, updatedAt: new Date() })
        .onConflictDoUpdate({
          target: [memoryViews.owner, memoryViews.name],
          set: { body, updatedAt: new Date() },
        });
    }

    if (sanitized.deleteSlugs.length > 0) {
      for (const slug of sanitized.deleteSlugs) {
        await client.delete(memoryPages).where(and(eq(memoryPages.owner, owner), eq(memoryPages.slug, slug)));
      }
    }

    await client
      .update(memoryEntries)
      .set({ consolidatedAt: new Date() })
      .where(
        and(
          eq(memoryEntries.owner, owner),
          isNull(memoryEntries.consolidatedAt),
          isNull(memoryEntries.deletedAt),
          lte(memoryEntries.createdAt, cutoff),
        ),
      );

    const error = sanitized.errors.length > 0 ? sanitized.errors.join("; ") : undefined;
    await client.insert(memoryRuns).values({
      owner,
      startedAt,
      finishedAt: new Date(),
      entriesCount: pending.length,
      pagesWritten: sanitized.pages.length,
      ok: true,
      error,
    });

    return { owner, entries: pending.length, pagesWritten: sanitized.pages.length, ok: true, error };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await client
      .insert(memoryRuns)
      .values({
        owner,
        startedAt,
        finishedAt: new Date(),
        entriesCount: pending.length,
        pagesWritten: 0,
        ok: false,
        error: message,
      })
      .catch(() => undefined); // best-effort audit row; don't mask the real error below.
    return { owner, entries: pending.length, pagesWritten: 0, ok: false, error: message };
  }
}

/** Cron entry point: every due owner, capped at MAX_OWNERS_PER_CRON_RUN. */
export async function consolidateDueOwners(client: DbClient, anthropic: Anthropic): Promise<ConsolidateResult[]> {
  const owners = (await dueOwners(client, new Date())).slice(0, MAX_OWNERS_PER_CRON_RUN);
  return Promise.all(owners.map((owner) => consolidateOwner(client, anthropic, owner)));
}

/** Run-now entry point: this owner only, due-ness ignored. */
export async function consolidateOwnerNow(client: DbClient, anthropic: Anthropic, owner: string): Promise<ConsolidateResult> {
  return consolidateOwner(client, anthropic, owner);
}

export { pendingStats };
