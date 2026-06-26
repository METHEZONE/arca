export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { listMemories } from "@/lib/secondbrain/store";

export async function GET(): Promise<NextResponse> {
  const memories = await listMemories();
  return NextResponse.json(memories);
}
