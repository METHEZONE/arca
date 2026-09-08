/**
 * Multi-tenant schema for ARCA Cloud.
 *
 * One user belongs to exactly one organization (the tenant). That is
 * deliberately not a join table — this is a small team's app, not an
 * enterprise product, and a users.organization_id column upgrades to a
 * membership table later if multi-org-per-user ever matters.
 */

import {
  bigserial,
  boolean,
  index,
  integer,
  pgEnum,
  pgTable,
  primaryKey,
  real,
  text,
  timestamp,
  uuid,
} from "drizzle-orm/pg-core";

/** Mirrors the published pricing tiers: Companion $0, Second Self $19, ZONE for Teams $99. */
export const planEnum = pgEnum("plan", ["free", "pro", "team"]);

export const organizations = pgTable("organizations", {
  id: uuid("id").defaultRandom().primaryKey(),
  name: text("name").notNull(),
  plan: planEnum("plan").notNull().default("free"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  /** Set by the weekly recap cron (Phase F) after a send — dedupes so a
   *  re-run within the same week (retry, manual trigger) doesn't double-send. */
  digestSentAt: timestamp("digest_sent_at", { withTimezone: true }),
});

export const users = pgTable("users", {
  id: uuid("id").defaultRandom().primaryKey(),
  email: text("email").notNull().unique(),
  organizationId: uuid("organization_id")
    .notNull()
    .references(() => organizations.id),
  /** Set once the account signs in with Google (Phase A) — attaches to the
   *  same row as a magic-link account with the matching verified email. */
  googleId: text("google_id").unique(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  /** Opts out of the weekly recap email (Phase F). Doesn't affect
   *  transactional mail (magic links, device-link confirmations). */
  digestOptOut: boolean("digest_opt_out").notNull().default(false),
});

/**
 * Anonymous device identities from `lib/arca/device.ts`. A row only exists
 * once a device has either made a metered call or been linked to an
 * account — issuing a token doesn't write here.
 *
 * `userId`/`organizationId` are null until the device is claimed (Phase 2's
 * "exchange"). A null-organization device is metered under the implicit
 * free tier, keyed by device id instead of tenant id.
 */
export const devices = pgTable("devices", {
  id: text("id").primaryKey(),
  userId: uuid("user_id").references(() => users.id),
  organizationId: uuid("organization_id").references(() => organizations.id),
  claimedAt: timestamp("claimed_at", { withTimezone: true }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const usageKindEnum = pgEnum("usage_kind", ["chat", "transcribe", "delegate"]);

/** Durable replacement for the single-line JSON logs `usage.ts` used to emit. */
export const usageEvents = pgTable(
  "usage_events",
  {
    id: bigserial("id", { mode: "number" }).primaryKey(),
    at: timestamp("at", { withTimezone: true }).notNull().defaultNow(),
    deviceId: text("device_id"),
    userId: uuid("user_id").references(() => users.id),
    organizationId: uuid("organization_id").references(() => organizations.id),
    kind: usageKindEnum("kind").notNull(),
    model: text("model"),
    inputTokens: integer("input_tokens"),
    outputTokens: integer("output_tokens"),
    audioSeconds: real("audio_seconds"),
    ok: boolean("ok").notNull(),
    error: text("error"),
  },
  (table) => [
    // Quota/rate-limit checks and the metering key overall are both
    // "events for this subject since some time" — this index serves both.
    index("usage_events_org_at_idx").on(table.organizationId, table.at),
    index("usage_events_device_at_idx").on(table.deviceId, table.at),
  ],
);

/** Single-use magic-link sign-in tokens (Phase 2). Only the hash is stored. */
export const magicLinks = pgTable("magic_links", {
  id: uuid("id").defaultRandom().primaryKey(),
  email: text("email").notNull(),
  tokenHash: text("token_hash").notNull().unique(),
  /** Device claimed at request time, before the emailed link is ever clicked
   *  — a query-param deviceId on the callback would let anyone attach an
   *  arbitrary device to someone else's account. */
  deviceId: text("device_id"),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  consumedAt: timestamp("consumed_at", { withTimezone: true }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

/**
 * ARCA Brain — the server-side memory substrate (docs/ARCA-BRAIN.md). Every
 * row is scoped by `owner` (see lib/brain/owner.ts), a free-form string like
 * "device:<id>" or "email:<addr>" — not a foreign key, since ownership can
 * predate any users/devices row existing.
 */

/** Append-only ledger of raw memory statements (Vellum's buffer.md). Never
 *  hard-deleted — `deletedAt` is the only removal path, and consolidation
 *  only ever sets `consolidatedAt`, it doesn't delete rows. */
export const memoryEntries = pgTable(
  "memory_entries",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    owner: text("owner").notNull(),
    text: text("text").notNull(),
    kind: text("kind").notNull().default("fact"),
    source: text("source").notNull().default("chat"),
    sourceRef: text("source_ref"),
    deviceId: text("device_id"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    consolidatedAt: timestamp("consolidated_at", { withTimezone: true }),
    deletedAt: timestamp("deleted_at", { withTimezone: true }),
  },
  (table) => [
    index("memory_entries_owner_created_idx").on(table.owner, table.createdAt),
    index("memory_entries_owner_consolidated_idx").on(table.owner, table.consolidatedAt),
  ],
);

/** Concept pages — the wiki article half of the substrate. Rewritten whole
 *  by consolidation, never patched in place. */
export const memoryPages = pgTable(
  "memory_pages",
  {
    owner: text("owner").notNull(),
    slug: text("slug").notNull(),
    title: text("title").notNull(),
    summary: text("summary").notNull(),
    body: text("body").notNull(),
    edges: text("edges").array().notNull().default([]),
    originDate: timestamp("origin_date", { withTimezone: true }),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.owner, table.slug] })],
);

/** Always-injected aggregate views: essentials / threads / recent. */
export const memoryViews = pgTable(
  "memory_views",
  {
    owner: text("owner").notNull(),
    name: text("name").notNull(),
    body: text("body").notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.owner, table.name] })],
);

/** Audit log for consolidation runs (cron and run-now). */
export const memoryRuns = pgTable("memory_runs", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  owner: text("owner").notNull(),
  startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
  finishedAt: timestamp("finished_at", { withTimezone: true }),
  entriesCount: integer("entries_count").notNull().default(0),
  pagesWritten: integer("pages_written").notNull().default(0),
  ok: boolean("ok").notNull().default(false),
  error: text("error"),
});
