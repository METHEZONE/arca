/**
 * Postgres via postgres.js, pointed at a Supabase project (Supavisor
 * transaction pooler, port 6543). The pooler is what keeps a serverless
 * function fleet from exhausting Postgres connections, so the client here
 * stays a plain TCP driver with `prepare: false` (transaction-mode poolers
 * don't support prepared statements). Any Postgres URL works — Supabase,
 * Neon, or a local instance — which is also why this isn't Neon's HTTP
 * driver: that one only speaks to Neon's proxy. Drizzle over Prisma because
 * it's a thin query builder with no codegen step.
 */

import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";

import * as schema from "@/lib/db/schema";

let cached: ReturnType<typeof drizzle<typeof schema>> | null = null;

/** Null when `DATABASE_URL` isn't set — callers decide how to degrade. */
export function db(): ReturnType<typeof drizzle<typeof schema>> | null {
  if (cached) return cached;
  const url = process.env.DATABASE_URL?.trim();
  if (!url) return null;
  const client = postgres(url, { prepare: false, max: 1 });
  cached = drizzle(client, { schema });
  return cached;
}

export function hasDatabase(): boolean {
  return Boolean(process.env.DATABASE_URL?.trim());
}
