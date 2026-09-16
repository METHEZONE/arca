import { neon, type NeonQueryFunction } from "@neondatabase/serverless";

type StoredRow = {
  key: string;
  value: unknown;
  tombstoned: boolean;
  updated_at: string;
};

let client: NeonQueryFunction<false, false> | undefined;
let schemaReady: Promise<void> | undefined;

export function durableStoreConfigured(): boolean {
  return Boolean(process.env.DATABASE_URL?.trim());
}

function database(): NeonQueryFunction<false, false> {
  const connectionString = process.env.DATABASE_URL?.trim();
  if (!connectionString) throw new Error("DATABASE_URL is not configured.");
  client ??= neon(connectionString);
  return client;
}

async function ensureSchema(): Promise<void> {
  schemaReady ??= (async () => {
    const sql = database();
    await sql`
      CREATE TABLE IF NOT EXISTS arca_kv (
        namespace TEXT NOT NULL,
        key TEXT NOT NULL,
        value JSONB,
        tombstoned BOOLEAN NOT NULL DEFAULT FALSE,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (namespace, key)
      )
    `;
    await sql`
      CREATE INDEX IF NOT EXISTS arca_kv_namespace_updated_idx
      ON arca_kv (namespace, updated_at DESC)
    `;
  })();
  await schemaReady;
}

export async function kvGet<T>(namespace: string, key: string): Promise<T | null> {
  await ensureSchema();
  const sql = database();
  const rows = await sql`
    SELECT value
    FROM arca_kv
    WHERE namespace = ${namespace} AND key = ${key} AND tombstoned = FALSE
    LIMIT 1
  `;
  return rows.length ? (rows[0].value as T) : null;
}

export async function kvPut(namespace: string, key: string, value: unknown): Promise<void> {
  await ensureSchema();
  const sql = database();
  await sql`
    INSERT INTO arca_kv (namespace, key, value, tombstoned, updated_at)
    VALUES (${namespace}, ${key}, ${JSON.stringify(value)}::jsonb, FALSE, NOW())
    ON CONFLICT (namespace, key) DO UPDATE
    SET value = EXCLUDED.value, tombstoned = FALSE, updated_at = NOW()
  `;
}

export async function kvClaim(
  namespace: string,
  key: string,
  value: unknown,
  staleAfterSeconds = 300,
): Promise<boolean> {
  await ensureSchema();
  const sql = database();
  const rows = await sql`
    INSERT INTO arca_kv (namespace, key, value, tombstoned, updated_at)
    VALUES (${namespace}, ${key}, ${JSON.stringify(value)}::jsonb, FALSE, NOW())
    ON CONFLICT (namespace, key) DO UPDATE
    SET value = EXCLUDED.value, tombstoned = FALSE, updated_at = NOW()
    WHERE arca_kv.tombstoned = TRUE
       OR arca_kv.updated_at < NOW() - (${staleAfterSeconds} * INTERVAL '1 second')
    RETURNING key
  `;
  return rows.length > 0;
}

export async function kvDelete(namespace: string, key: string): Promise<boolean> {
  await ensureSchema();
  const sql = database();
  const rows = await sql`
    DELETE FROM arca_kv
    WHERE namespace = ${namespace} AND key = ${key}
    RETURNING key
  `;
  return rows.length > 0;
}

export async function kvTombstone(namespace: string, key: string): Promise<void> {
  await ensureSchema();
  const sql = database();
  await sql`
    INSERT INTO arca_kv (namespace, key, value, tombstoned, updated_at)
    VALUES (${namespace}, ${key}, NULL, TRUE, NOW())
    ON CONFLICT (namespace, key) DO UPDATE
    SET value = NULL, tombstoned = TRUE, updated_at = NOW()
  `;
}

export async function kvIsTombstoned(namespace: string, key: string): Promise<boolean> {
  await ensureSchema();
  const sql = database();
  const rows = await sql`
    SELECT tombstoned
    FROM arca_kv
    WHERE namespace = ${namespace} AND key = ${key}
    LIMIT 1
  `;
  return rows[0]?.tombstoned === true;
}

export async function kvList<T>(namespace: string, keyPrefix?: string): Promise<Array<{ key: string; value: T; updatedAt: string }>> {
  await ensureSchema();
  const sql = database();
  const rows = keyPrefix === undefined
    ? await sql`
        SELECT key, value, tombstoned, updated_at
        FROM arca_kv
        WHERE namespace = ${namespace} AND tombstoned = FALSE
        ORDER BY updated_at DESC
      `
    : await sql`
        SELECT key, value, tombstoned, updated_at
        FROM arca_kv
        WHERE namespace = ${namespace}
          AND LEFT(key, ${keyPrefix.length}) = ${keyPrefix}
          AND tombstoned = FALSE
        ORDER BY updated_at DESC
      `;

  return (rows as StoredRow[]).map((row) => ({
    key: row.key,
    value: row.value as T,
    updatedAt: row.updated_at,
  }));
}

export async function kvDeletePrefix(namespace: string, keyPrefix: string): Promise<number> {
  await ensureSchema();
  const sql = database();
  const rows = await sql`
    DELETE FROM arca_kv
    WHERE namespace = ${namespace} AND LEFT(key, ${keyPrefix.length}) = ${keyPrefix}
    RETURNING key
  `;
  return rows.length;
}
