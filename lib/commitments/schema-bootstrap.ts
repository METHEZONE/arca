/**
 * Idempotent bootstrap for the commitment-loop tables. The Vercel deployment's
 * DATABASE_URL is not reachable from the dev machine, and drizzle migrations
 * are applied by hand in this repo, so the first request in each runtime
 * creates what's missing (CREATE ... IF NOT EXISTS). Mirrors
 * drizzle/0006_commitment_loop.sql exactly.
 */

import { sql } from "drizzle-orm";

import { db } from "@/lib/db/client";

let ready: Promise<void> | null = null;

const STATEMENTS = [
  `DO $$ BEGIN
     IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'commitment_status') THEN
       CREATE TYPE "public"."commitment_status" AS ENUM('detected','proposed','accepted','authorized','in_progress','evidence_submitted','verified');
     END IF;
   END $$;`,
  `CREATE TABLE IF NOT EXISTS "profiles" (
     "user_id" uuid PRIMARY KEY NOT NULL REFERENCES "public"."users"("id"),
     "display_name" text, "headline" text, "company" text, "company_url" text, "avatar_url" text,
     "sources" jsonb DEFAULT '[]'::jsonb NOT NULL,
     "confirmed_at" timestamp with time zone,
     "created_at" timestamp with time zone DEFAULT now() NOT NULL,
     "updated_at" timestamp with time zone DEFAULT now() NOT NULL
   );`,
  `CREATE TABLE IF NOT EXISTS "commitments" (
     "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
     "user_id" uuid NOT NULL REFERENCES "public"."users"("id"),
     "title" text NOT NULL, "counterpart" text, "due" text, "outcome" text NOT NULL,
     "source_quote" text, "source_kind" text DEFAULT 'text' NOT NULL, "source_summary" text, "source_transcript" text,
     "status" "commitment_status" DEFAULT 'detected' NOT NULL,
     "scope_start" integer, "scope_end" integer,
     "created_at" timestamp with time zone DEFAULT now() NOT NULL,
     "updated_at" timestamp with time zone DEFAULT now() NOT NULL
   );`,
  `CREATE TABLE IF NOT EXISTS "commitment_nodes" (
     "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
     "commitment_id" uuid NOT NULL REFERENCES "public"."commitments"("id"),
     "position" integer NOT NULL, "title" text NOT NULL, "kind" text NOT NULL,
     "risky" boolean DEFAULT false NOT NULL, "question" text,
     "status" text DEFAULT 'pending' NOT NULL,
     "artifact" text, "evidence" text, "evidence_kind" text, "evidence_at" timestamp with time zone,
     "updated_at" timestamp with time zone DEFAULT now() NOT NULL
   );`,
  `CREATE TABLE IF NOT EXISTS "feedback_events" (
     "id" bigserial PRIMARY KEY NOT NULL,
     "at" timestamp with time zone DEFAULT now() NOT NULL,
     "user_id" uuid NOT NULL REFERENCES "public"."users"("id"),
     "commitment_id" uuid REFERENCES "public"."commitments"("id"),
     "node_id" uuid REFERENCES "public"."commitment_nodes"("id"),
     "rail" text NOT NULL, "value" text NOT NULL, "note" text
   );`,
  `CREATE INDEX IF NOT EXISTS "commitments_user_created_idx" ON "commitments" USING btree ("user_id","created_at");`,
  `CREATE INDEX IF NOT EXISTS "commitment_nodes_commitment_idx" ON "commitment_nodes" USING btree ("commitment_id","position");`,
  `CREATE INDEX IF NOT EXISTS "feedback_events_user_at_idx" ON "feedback_events" USING btree ("user_id","at");`,
];

export function ensureCommitmentSchema(): Promise<void> {
  if (ready) return ready;
  ready = (async () => {
    const database = db();
    if (!database) return;
    for (const statement of STATEMENTS) {
      try {
        await database.execute(sql.raw(statement));
      } catch (err) {
        // Concurrent cold starts can race on CREATE; "already exists" is fine.
        const message = err instanceof Error ? err.message : String(err);
        if (!/already exists|duplicate/i.test(message)) {
          ready = null;
          throw err;
        }
      }
    }
  })();
  return ready;
}
