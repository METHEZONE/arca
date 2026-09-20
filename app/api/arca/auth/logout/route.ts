import { NextRequest, NextResponse } from "next/server";

import { SESSION_COOKIE } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const res = NextResponse.redirect(new URL("/arca", request.nextUrl.origin));
  res.cookies.delete(SESSION_COOKIE);
  res.cookies.delete("arca_ghint");
  return res;
}
