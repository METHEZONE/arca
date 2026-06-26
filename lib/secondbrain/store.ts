import { mkdir, readFile, writeFile, unlink, readdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { randomUUID } from "node:crypto";
import { dataDir } from "@/lib/config";
import type { Memory, MemorySummary, ActionStatus } from "@/lib/types";
import { toMemorySummary } from "@/lib/types";

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
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw err;
  }
}

export async function listMemories(): Promise<MemorySummary[]> {
  await ensureDir();
  let entries: string[];
  try {
    entries = await readdir(memoriesDir());
  } catch {
    return [];
  }

  const summaries: MemorySummary[] = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    try {
      const raw = await readFile(join(memoriesDir(), entry), "utf-8");
      const memory = JSON.parse(raw) as Memory;
      summaries.push(toMemorySummary(memory));
    } catch {
      // Skip corrupt/unreadable files
    }
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
  try {
    await unlink(memoryPath(id));
    return true;
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw err;
  }
}

export function newMemoryId(): string {
  return `${Date.now().toString(36)}-${randomUUID().slice(0, 8)}`;
}
