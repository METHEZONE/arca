import { NextRequest, NextResponse } from "next/server";
import { eq } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { verifyUnsubscribeToken } from "@/lib/arca/digest";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function html(body: string) {
  return new NextResponse(
    `<!doctype html><html><head><meta charset="utf-8"><title>ARCA</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{font:16px system-ui;max-width:32rem;margin:4rem auto;padding:0 1.5rem;color:#1a1a1a}</style>
    </head><body>${body}</body></html>`,
    { headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

/** One-click unsubscribe from the weekly recap email — the link in every
 *  digest (`lib/arca/digest.ts`). Doesn't touch magic-link/device-link mail,
 *  those are transactional, not the recap. */
export async function GET(request: NextRequest) {
  const token = request.nextUrl.searchParams.get("token");
  const userId = token ? await verifyUnsubscribeToken(token) : null;
  if (!userId) {
    return html("<h1>Link expired</h1><p>This unsubscribe link is no longer valid.</p>");
  }

  const database = db();
  if (!database) {
    return html("<h1>Unavailable</h1><p>Try again shortly.</p>");
  }
  try {
    await database.update(users).set({ digestOptOut: true }).where(eq(users.id, userId));
  } catch (err) {
    console.error("arca.digest.unsubscribe_failed", err instanceof Error ? err.message : err);
    return html("<h1>Something went wrong</h1><p>Try the link again in a minute.</p>");
  }

  return html("<h1>Unsubscribed</h1><p>You won&rsquo;t get the weekly recap anymore.</p>");
}
