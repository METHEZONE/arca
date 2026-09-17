import { NextRequest, NextResponse } from "next/server";

import { consumeMagicLink } from "@/lib/arca/magiclink";
import { claimDevice } from "@/lib/arca/identity";
import { issueSession, setSessionCookie } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ONBOARDING = "/arca/onboarding";

/**
 * Step 2 of sign-in: the link the user clicked.
 *
 * GET no longer consumes the token. In production the very first emailed link
 * was burned 23 seconds after it was sent — by a mail-side link scanner, not a
 * person — so the human who clicked it got "invalid or already used". GET now
 * renders a tiny interstitial that auto-submits a POST (scanners don't run JS
 * or POST); the POST is what consumes the single-use token, creates the
 * account on first sign-in, claims the device captured at request time (if
 * any), issues the session cookie and hands off into web onboarding. The
 * Swift app doesn't use this browser route.
 */
export async function GET(request: NextRequest) {
  const token = request.nextUrl.searchParams.get("token");
  if (!token) {
    return errorRedirect(request, "missing_token");
  }
  return new NextResponse(interstitial(token), {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
    },
  });
}

export async function POST(request: NextRequest) {
  let token: string | null = null;
  const contentType = request.headers.get("content-type") ?? "";
  try {
    if (contentType.includes("application/json")) {
      token = ((await request.json()) as { token?: string }).token ?? null;
    } else {
      token = (await request.formData()).get("token")?.toString() ?? null;
    }
  } catch {
    token = null;
  }
  if (!token) {
    return errorRedirect(request, "missing_token");
  }

  // A DB blip anywhere below must still land the user somewhere with a way
  // forward, not a raw 500 — same guard as the Google callback.
  try {
    const consumed = await consumeMagicLink(token);
    if (!consumed) {
      return errorRedirect(request, "invalid_link");
    }

    if (consumed.deviceId) {
      await claimDevice(consumed.deviceId, consumed.userId, consumed.organizationId);
    }

    const sessionToken = await issueSession({
      userId: consumed.userId,
      organizationId: consumed.organizationId,
      email: consumed.email,
    });

    // 303: a POST that ends in a redirect must be followed with GET.
    const res = NextResponse.redirect(new URL(`${ONBOARDING}?step=device`, request.nextUrl.origin), 303);
    setSessionCookie(res, sessionToken);
    return res;
  } catch (err) {
    console.error("arca.auth.callback_failed", err instanceof Error ? err.message : err);
    return errorRedirect(request, "server_error");
  }
}

function errorRedirect(request: NextRequest, code: string) {
  return NextResponse.redirect(
    new URL(`${ONBOARDING}?step=signin&error=${code}`, request.nextUrl.origin),
    303,
  );
}

function escapeAttr(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

function interstitial(token: string): string {
  const t = escapeAttr(token);
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Signing you in — ARCA</title>
<style>
html,body{margin:0;height:100%;background:#000;color:#ffedd7;font-family:-apple-system,BlinkMacSystemFont,"Pretendard","Spline Sans",sans-serif;letter-spacing:-0.01em}
main{min-height:100%;display:grid;place-items:center;padding:24px}
.card{max-width:420px;width:100%;text-align:center}
h1{font-size:22px;margin:0 0 8px;font-weight:600}
p{margin:0 0 22px;opacity:.7;line-height:1.55;font-size:15px}
button{background:#dc5000;color:#fff;border:0;border-radius:999px;padding:12px 22px;font-size:15px;font-weight:700;cursor:pointer}
.k{font-size:11px;letter-spacing:.22em;text-transform:uppercase;opacity:.55;margin-bottom:18px}
</style></head><body><main><div class="card">
<div class="k">ARCA</div>
<h1>Signing you in…</h1>
<p>One tap and you're in. If nothing happens, press the button.</p>
<form method="post" action="" id="f"><input type="hidden" name="token" value="${t}"><button type="submit">Continue to ARCA</button></form>
</div></main>
<script>setTimeout(function(){document.getElementById("f").submit()},150)</script>
</body></html>`;
}
