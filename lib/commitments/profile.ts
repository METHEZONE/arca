import { eq } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { profiles, type ProfileSource } from "@/lib/db/schema";
import { ensureCommitmentSchema } from "./schema-bootstrap";

export type ProfileRow = typeof profiles.$inferSelect;

export async function getProfile(userId: string): Promise<ProfileRow | null> {
  const database = db();
  if (!database) return null;
  await ensureCommitmentSchema();
  const [row] = await database.select().from(profiles).where(eq(profiles.userId, userId)).limit(1);
  return row ?? null;
}

export async function hasConfirmedProfile(userId: string): Promise<boolean> {
  const p = await getProfile(userId);
  return Boolean(p?.confirmedAt);
}

/** Writes ONLY what the user confirmed. Replaces the row wholesale so a
 *  correction never leaves stale inferred fields behind. */
export async function confirmProfile(
  userId: string,
  input: { displayName: string | null; headline: string | null; company: string | null; companyUrl: string | null; avatarUrl: string | null; sources: ProfileSource[] },
): Promise<ProfileRow> {
  const database = db();
  if (!database) throw new Error("DATABASE_URL is not set.");
  await ensureCommitmentSchema();
  const values = {
    userId,
    displayName: input.displayName?.slice(0, 120) || null,
    headline: input.headline?.slice(0, 200) || null,
    company: input.company?.slice(0, 120) || null,
    companyUrl: input.companyUrl?.slice(0, 300) || null,
    avatarUrl: input.avatarUrl?.slice(0, 500) || null,
    sources: input.sources.slice(0, 10),
    confirmedAt: new Date(),
    updatedAt: new Date(),
  };
  const [row] = await database
    .insert(profiles)
    .values(values)
    .onConflictDoUpdate({ target: profiles.userId, set: values })
    .returning();
  return row;
}

export async function deleteProfile(userId: string): Promise<void> {
  const database = db();
  if (!database) return;
  await ensureCommitmentSchema();
  await database.delete(profiles).where(eq(profiles.userId, userId));
}
