export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { artifactUrl, isDownloadTarget, recordDownload } from "@/lib/arca/downloads";

/**
 * Tracked download hand-off. `?t=mac-dmg|mac-zip|ios-testflight&src=…`
 * writes one `downloads` row (who/where/what) and redirects to the artifact.
 * Unknown targets fall back to the /download page rather than erroring.
 */
export async function GET(req: Request): Promise<NextResponse> {
  const url = new URL(req.url);
  const target = url.searchParams.get("t");
  if (!isDownloadTarget(target)) {
    return NextResponse.redirect(new URL("/download", url.origin), 302);
  }
  const dest = artifactUrl(target);
  await recordDownload({ request: req, target, url: dest, source: url.searchParams.get("src") });
  return NextResponse.redirect(dest, { status: 302, headers: { "Cache-Control": "no-store" } });
}
