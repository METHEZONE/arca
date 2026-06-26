import { NextResponse } from "next/server";
import { capabilities } from "@/lib/config";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  return NextResponse.json(capabilities());
}
