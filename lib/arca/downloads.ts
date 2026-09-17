/**
 * Download tracking — who pulled which build, from where.
 *
 * Every public download button goes through GET /api/arca/download?t=…,
 * which writes one row here and 302s to the artifact. Signed beta links do
 * the same with the tester's email attached. Identity is best-effort: a
 * signed-in web session gives email + userId, a device header gives the
 * device, otherwise the row is anonymous (hashed IP + geo + user agent).
 */

import { createHash } from "node:crypto";
import { desc, sql } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { downloads } from "@/lib/db/schema";
import { deviceIdFromRequest } from "@/lib/arca/device";
import { sessionFromRequest } from "@/lib/arca/session";
import { betaZipUrl, TESTFLIGHT_URL } from "@/lib/beta";

export type DownloadTarget = "mac-dmg" | "mac-zip" | "ios-testflight" | "beta-signed";

const TARGETS: ReadonlySet<string> = new Set(["mac-dmg", "mac-zip", "ios-testflight"]);

export function isDownloadTarget(value: string | null | undefined): value is Exclude<DownloadTarget, "beta-signed"> {
  return Boolean(value && TARGETS.has(value));
}

/** The DMG is the primary Mac artifact; ARCA_BETA_DMG_URL overrides the GitHub "latest" asset. */
export function betaDmgUrl(): string {
  return (
    process.env.ARCA_BETA_DMG_URL?.trim() ||
    "https://github.com/METHEZONE/arca/releases/latest/download/ARCA-Beta-mac.dmg"
  );
}

export function artifactUrl(target: Exclude<DownloadTarget, "beta-signed">): string {
  switch (target) {
    case "mac-dmg":
      return betaDmgUrl();
    case "mac-zip":
      return betaZipUrl();
    case "ios-testflight":
      return TESTFLIGHT_URL;
  }
}

function ipHash(request: Request): string | null {
  const ip =
    request.headers.get("x-real-ip") ||
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    null;
  if (!ip) return null;
  // Daily salt: the same machine hashes the same within a day, differently across days.
  const day = new Date().toISOString().slice(0, 10);
  return createHash("sha256").update(`${ip}|${day}|${process.env.ARCA_DEVICE_SECRET ?? ""}`).digest("base64url").slice(0, 24);
}

function geo(request: Request, name: string): string | null {
  const v = request.headers.get(name);
  if (!v) return null;
  try {
    return decodeURIComponent(v);
  } catch {
    return v;
  }
}

export interface RecordDownloadInput {
  request: Request;
  target: DownloadTarget;
  url: string;
  /** Known email (signed beta link). Falls back to the web session's email. */
  email?: string | null;
  source?: string | null;
}

/** Never throws — a logging failure must not block the download. */
export async function recordDownload(input: RecordDownloadInput): Promise<void> {
  const database = db();
  if (!database) return;
  try {
    const session = await sessionFromRequest(input.request).catch(() => null);
    const ua = input.request.headers.get("user-agent");
    await database.insert(downloads).values({
      target: input.target,
      url: input.url,
      email: (input.email ?? session?.email ?? null)?.toLowerCase() ?? null,
      userId: session?.userId ?? null,
      deviceId: deviceIdFromRequest(input.request),
      source: input.source?.slice(0, 80) ?? null,
      referer: input.request.headers.get("referer")?.slice(0, 500) ?? null,
      userAgent: ua?.slice(0, 500) ?? null,
      ipHash: ipHash(input.request),
      country: geo(input.request, "x-vercel-ip-country"),
      region: geo(input.request, "x-vercel-ip-country-region"),
      city: geo(input.request, "x-vercel-ip-city"),
    });
  } catch (err) {
    console.error("[downloads] record failed:", err instanceof Error ? err.message : err);
  }
}

export interface DownloadSummary {
  total: number;
  byTarget: Record<string, number>;
  uniqueMachines: number;
  withEmail: number;
  recent: Array<{
    at: string;
    target: string;
    email: string | null;
    source: string | null;
    country: string | null;
    city: string | null;
    userAgent: string | null;
    referer: string | null;
  }>;
}

export async function summarizeDownloads(limit = 100): Promise<DownloadSummary | null> {
  const database = db();
  if (!database) return null;
  const recentRows = await database
    .select({
      at: downloads.at,
      target: downloads.target,
      email: downloads.email,
      source: downloads.source,
      country: downloads.country,
      city: downloads.city,
      userAgent: downloads.userAgent,
      referer: downloads.referer,
    })
    .from(downloads)
    .orderBy(desc(downloads.at))
    .limit(limit);
  const [agg] = await database
    .select({
      total: sql<number>`count(*)::int`,
      uniqueMachines: sql<number>`count(distinct ${downloads.ipHash})::int`,
      withEmail: sql<number>`count(${downloads.email})::int`,
    })
    .from(downloads);
  const perTarget = await database
    .select({ target: downloads.target, n: sql<number>`count(*)::int` })
    .from(downloads)
    .groupBy(downloads.target);
  return {
    total: agg?.total ?? 0,
    uniqueMachines: agg?.uniqueMachines ?? 0,
    withEmail: agg?.withEmail ?? 0,
    byTarget: Object.fromEntries(perTarget.map((r) => [r.target, r.n])),
    recent: recentRows.map((r) => ({ ...r, at: r.at.toISOString() })),
  };
}
