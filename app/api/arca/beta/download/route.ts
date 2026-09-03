export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { betaZipUrl, verifyGrant } from "@/lib/beta";

// The link a tester receives. Valid signature + not expired → the build.
export async function GET(req: Request): Promise<NextResponse> {
  const url = new URL(req.url);
  const email = url.searchParams.get("e") ?? "";
  const exp = Number(url.searchParams.get("x") ?? 0);
  const sig = url.searchParams.get("s") ?? "";
  let ok = false;
  try {
    ok = verifyGrant(email, exp, sig);
  } catch {
    ok = false;
  }
  if (!ok) {
    return new NextResponse(
      `<!doctype html><meta charset="utf-8"><body style="font-family:-apple-system,sans-serif;max-width:520px;margin:80px auto;line-height:1.6">
      <h2>링크가 만료됐거나 올바르지 않아요</h2><p>베타 다운로드 링크는 발급 후 14일까지 유효합니다. 새 링크가 필요하면 me@thezonebio.com 으로 알려주세요.</p></body>`,
      { status: 403, headers: { "Content-Type": "text/html; charset=utf-8" } }
    );
  }
  return NextResponse.redirect(betaZipUrl(), 302);
}
