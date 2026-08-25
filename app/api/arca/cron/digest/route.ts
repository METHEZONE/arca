import { NextRequest, NextResponse } from "next/server";

import { sendWeeklyDigests } from "@/lib/arca/digest";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Weekly recap cron (Phase F). Triggered by Vercel Cron per `vercel.json`;
 * Vercel signs cron requests with `Authorization: Bearer $CRON_SECRET`
 * automatically when `CRON_SECRET` is set, so this checks that header the
 * same way Vercel's own docs recommend — no new auth mechanism.
 */
export async function GET(request: NextRequest) {
  const secret = process.env.CRON_SECRET?.trim();
  if (secret) {
    const auth = request.headers.get("authorization");
    if (auth !== `Bearer ${secret}`) {
      return NextResponse.json({ error: "Unauthorized." }, { status: 401 });
    }
  }

  const result = await sendWeeklyDigests(request.nextUrl.origin);
  return NextResponse.json(result);
}
