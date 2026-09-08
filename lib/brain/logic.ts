// Pure functions for ARCA Brain — no I/O, so they're covered by
// lib/brain/logic.test.ts without a database. docs/ARCA-BRAIN.md §5, §8.

export const SLUG_REGEX = /^[a-z0-9가-힣][a-z0-9가-힣-]*(\/[a-z0-9가-힣][a-z0-9가-힣-]*){0,2}$/;

export const CAPS = {
  slug: 80,
  body: 3000,
  summary: 300,
  essentials: 6000,
  threads: 6000,
  recent: 1500,
} as const;

const EIGHT_HOURS_MS = 8 * 60 * 60 * 1000;

/** Vellum's due rule, verbatim: 10+ pending, or 1+ pending stale 8h+. */
export function isDue(pendingCount: number, oldestPendingAt: Date | null, now: Date): boolean {
  if (pendingCount >= 10) return true;
  if (pendingCount >= 1 && oldestPendingAt) {
    return now.getTime() - oldestPendingAt.getTime() >= EIGHT_HOURS_MS;
  }
  return false;
}

export interface WriteMemoryPage {
  slug: string;
  title: string;
  summary: string;
  body: string;
  edges: string[];
  origin_date: string | null;
}

export interface WriteMemoryViews {
  essentials: string;
  threads: string;
  recent: string;
}

/** The `write_memory` tool-call payload, as Anthropic returns it — untrusted
 *  shape, hence every field below is optional/unknown until sanitized. */
export interface WriteMemoryOutput {
  pages?: unknown;
  views?: Partial<Record<keyof WriteMemoryViews, unknown>>;
  delete_slugs?: unknown;
}

export interface SanitizedWriteMemory {
  pages: WriteMemoryPage[];
  views: Partial<WriteMemoryViews>;
  deleteSlugs: string[];
  errors: string[];
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) : s;
}

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.length > 0;
}

/** Validates and clamps a model tool-call before it touches the database.
 *  `existingSlugs` are the owner's pages that already exist (before this
 *  write) — used to keep edges/delete_slugs from referencing nothing. */
export function sanitizeWriteMemory(
  output: WriteMemoryOutput | null | undefined,
  existingSlugs: string[],
): SanitizedWriteMemory {
  const errors: string[] = [];
  const existing = new Set(existingSlugs);
  const rawPages = Array.isArray(output?.pages) ? output.pages : [];

  const pages: WriteMemoryPage[] = [];
  for (const raw of rawPages as Array<Record<string, unknown>>) {
    const slug = typeof raw?.slug === "string" ? raw.slug.trim() : "";
    if (!slug || slug.length > CAPS.slug || !SLUG_REGEX.test(slug)) {
      errors.push(`invalid slug: ${JSON.stringify(raw?.slug ?? null)}`);
      continue;
    }
    pages.push({
      slug,
      title: typeof raw.title === "string" ? raw.title : "",
      summary: truncate(typeof raw.summary === "string" ? raw.summary : "", CAPS.summary),
      body: truncate(typeof raw.body === "string" ? raw.body : "", CAPS.body),
      edges: Array.isArray(raw.edges) ? raw.edges.filter((e): e is string => typeof e === "string") : [],
      origin_date: typeof raw.origin_date === "string" ? raw.origin_date : null,
    });
  }

  // Edges may only point at pages that exist after this write — either
  // already on disk, or written just now.
  const knownSlugs = new Set([...existing, ...pages.map((p) => p.slug)]);
  for (const page of pages) {
    page.edges = page.edges.filter((slug) => knownSlugs.has(slug) && slug !== page.slug);
  }

  const rawViews = output?.views ?? {};
  const views: Partial<WriteMemoryViews> = {};
  if (isNonEmptyString(rawViews.essentials)) views.essentials = truncate(rawViews.essentials, CAPS.essentials);
  if (isNonEmptyString(rawViews.threads)) views.threads = truncate(rawViews.threads, CAPS.threads);
  if (isNonEmptyString(rawViews.recent)) views.recent = truncate(rawViews.recent, CAPS.recent);

  const deleteSlugs = Array.isArray(output?.delete_slugs)
    ? output.delete_slugs.filter((slug): slug is string => typeof slug === "string" && existing.has(slug))
    : [];

  return { pages, views, deleteSlugs, errors };
}

const KST_FORMATTER = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Seoul",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

export interface BufferEntry {
  text: string;
  source: string;
  createdAt: Date | string;
}

/** `- [YYYY-MM-DD HH:mm · source] text`, in Asia/Seoul — the format the
 *  consolidation prompt's "새 기억" section expects for each buffer line. */
export function renderBufferLine(entry: BufferEntry): string {
  const date = typeof entry.createdAt === "string" ? new Date(entry.createdAt) : entry.createdAt;
  const parts = KST_FORMATTER.formatToParts(date);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  // Some ICU builds render midnight as "24:00" even with hour12:false.
  const hour = get("hour") === "24" ? "00" : get("hour");
  const stamp = `${get("year")}-${get("month")}-${get("day")} ${hour}:${get("minute")}`;
  return `- [${stamp} · ${entry.source}] ${entry.text}`;
}
