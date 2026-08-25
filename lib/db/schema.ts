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
});

export const users = pgTable("users", {
  id: uuid("id").defaultRandom().primaryKey(),
  email: text("email").notNull().unique(),
  organizationId: uuid("organization_id")
    .notNull()
    .references(() => organizations.id),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
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

export const usageKindEnum = pgEnum("usage_kind", ["chat", "transcribe"]);

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
