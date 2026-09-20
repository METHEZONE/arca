import { NextRequest, NextResponse } from "next/server";

import { isResponse, requireSession } from "@/lib/commitments/auth";
import { listCommitments, tasteModel } from "@/lib/commitments/store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const [items, taste] = await Promise.all([listCommitments(session.userId), tasteModel(session.userId)]);
  return NextResponse.json({ items, taste });
}
