import { mkdir, readFile, writeFile, unlink, readdir, access } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { randomUUID } from "node:crypto";
import { dataDir } from "@/lib/config";
import type { Memory, MemorySummary, ActionStatus } from "@/lib/types";
import { toMemorySummary } from "@/lib/types";
import { getShowcaseMemory, isShowcaseId, showcaseMemories } from "./showcase";

const ID_RE = /^[A-Za-z0-9_-]+$/;
const DEFAULT_DATA_DIR = "data";

function memoriesDir(): string {
  const configured = dataDir();
  const base = storageBaseDir(configured);
  return join(base, "memories");
}

function storageBaseDir(configured: string): string {
  if (process.env.VERCEL && !isAbsolute(configured)) return join("/tmp", configured);
  if (isAbsolute(configured)) return configured;
  if (configured === DEFAULT_DATA_DIR) return join(process.cwd(), DEFAULT_DATA_DIR);
  return join(/* turbopackIgnore: true */ process.cwd(), configured);
}

function validateId(id: string): void {
  if (!ID_RE.test(id)) {
    throw new Error(`Invalid memory id: "${id}"`);
  }
}

async function ensureDir(): Promise<void> {
  await mkdir(memoriesDir(), { recursive: true });
}

function memoryPath(id: string): string {
  return join(memoriesDir(), `${id}.json`);
}

// A deleted showcase memory leaves a tombstone so it stays deleted even
// though its source is compiled into the app.
function tombstonePath(id: string): string {
  return join(memoriesDir(), `${id}.tombstone`);
}

async function isTombstoned(id: string): Promise<boolean> {
  try {
    await access(tombstonePath(id));
    return true;
  } catch {
    return false;
  }
}

export async function saveMemory(memory: Memory): Promise<void> {
  validateId(memory.id);
  await ensureDir();
  await writeFile(memoryPath(memory.id), JSON.stringify(memory, null, 2), "utf-8");
}

export async function getMemory(id: string): Promise<Memory | null> {
  validateId(id);
  try {
    const raw = await readFile(memoryPath(id), "utf-8");
    return JSON.parse(raw) as Memory;
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }
  if (isShowcaseId(id) && !(await isTombstoned(id))) {
    return getShowcaseMemory(id);
  }
  return null;
}

export async function listMemories(): Promise<MemorySummary[]> {
  await ensureDir();
  let entries: string[] = [];
  try {
    entries = await readdir(memoriesDir());
  } catch {
    // Fall through with an empty disk listing — showcase still applies.
  }

  const summaries: MemorySummary[] = [];
  const diskIds = new Set<string>();
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    try {
      const raw = await readFile(join(memoriesDir(), entry), "utf-8");
      const memory = JSON.parse(raw) as Memory;
      diskIds.add(memory.id);
      summaries.push(toMemorySummary(memory));
    } catch {
      // Skip corrupt/unreadable files
    }
  }

  // Showcase memories ride along until materialized (edited) or tombstoned
  // (deleted), so a fresh deploy never opens onto an empty feed.
  for (const memory of showcaseMemories()) {
    if (diskIds.has(memory.id)) continue;
    if (await isTombstoned(memory.id)) continue;
    summaries.push(toMemorySummary(memory));
  }

  summaries.sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0));
  return summaries;
}

export async function updateMemory(
  id: string,
  patch: Partial<Memory>
): Promise<Memory | null> {
  const existing = await getMemory(id);
  if (!existing) return null;
  const updated: Memory = {
    ...existing,
    ...patch,
    id: existing.id,
    updatedAt: new Date().toISOString(),
  };
  await saveMemory(updated);
  return updated;
}

export async function setActionItemStatus(
  memoryId: string,
  actionItemId: string,
  status: ActionStatus
): Promise<Memory | null> {
  const memory = await getMemory(memoryId);
  if (!memory) return null;
  const items = memory.analysis.actionItems.map((item) =>
    item.id === actionItemId ? { ...item, status } : item
  );
  const updated: Memory = {
    ...memory,
    analysis: { ...memory.analysis, actionItems: items },
    updatedAt: new Date().toISOString(),
  };
  await saveMemory(updated);
  return updated;
}

export async function deleteMemory(id: string): Promise<boolean> {
  validateId(id);
  let removed = false;
  try {
    await unlink(memoryPath(id));
    removed = true;
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }
  // Tombstone showcase ids so they don't resurface from the compiled source
  // on the next list (whether or not a materialized copy was just removed).
  if (isShowcaseId(id) && getShowcaseMemory(id) && !(await isTombstoned(id))) {
    await ensureDir();
    await writeFile(tombstonePath(id), new Date().toISOString(), "utf-8");
    removed = true;
  }
  return removed;
}

export function newMemoryId(): string {
  return `${Date.now().toString(36)}-${randomUUID().slice(0, 8)}`;
}
