export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { adminTokenOk } from "@/lib/beta";
import { summarizeDownloads } from "@/lib/arca/downloads";

// Owner only: who downloaded what. Read from /arcadash.
export async function GET(req: Request): Promise<NextResponse> {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? null;
  if (!adminTokenOk(token)) return NextResponse.json({ ok: false, error: "unauthorized" }, { status: 401 });
  const summary = await summarizeDownloads(200);
  if (!summary) return NextResponse.json({ ok: false, error: "no database configured" }, { status: 503 });
  return NextResponse.json({ ok: true, ...summary });
}
