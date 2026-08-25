/**
 * Neon Postgres, accessed through its HTTP driver.
 *
 * Picked over Vercel's own Postgres product and Supabase because it's a
 * one-line `neon(url)` call with no connection pool to manage — every other
 * driver (`pg`, `postgres.js`) opens a TCP connection per invocation, which
 * is the classic way to exhaust Postgres' connection limit from a
 * serverless function fleet. Drizzle over Prisma because it's a thin
 * query builder with no generated client/codegen step, which matches how
 * light the rest of this repo's dependency footprint is.
 */

import { neon } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";

import * as schema from "@/lib/db/schema";

let cached: ReturnType<typeof drizzle<typeof schema>> | null = null;

/** Null when `DATABASE_URL` isn't set — callers decide how to degrade. */
export function db(): ReturnType<typeof drizzle<typeof schema>> | null {
  if (cached) return cached;
  const url = process.env.DATABASE_URL?.trim();
  if (!url) return null;
  cached = drizzle(neon(url), { schema });
  return cached;
}

export function hasDatabase(): boolean {
  return Boolean(process.env.DATABASE_URL?.trim());
}
