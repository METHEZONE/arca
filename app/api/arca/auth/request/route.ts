import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { createMagicLink } from "@/lib/arca/magiclink";
import { deviceIdFromRequest } from "@/lib/arca/device";
import { hasDatabase } from "@/lib/db/client";
import { sendMail } from "@/lib/mail/send";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({ email: z.string().trim().email() });

/**
 * Step 1 of sign-in: mint a magic link and email it.
 *
 * Always responds `{ ok: true }` regardless of whether the email exists yet
 * (it will, on first sign-in) — an error response here would let a caller
 * enumerate accounts. The optional device token identifies which device to
 * claim once the link is clicked, so a beta user's existing history survives
 * signing up.
 */
export async function POST(request: NextRequest) {
  if (!hasDatabase()) {
    return NextResponse.json(
      { error: "ARCA Cloud has no database configured." },
      { status: 503 },
    );
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Body must be JSON." }, { status: 400 });
  }
  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ error: "A valid `email` is required." }, { status: 400 });
  }

  const deviceId = deviceIdFromRequest(request);
  const token = await createMagicLink(parsed.data.email, deviceId);
  const link = `${request.nextUrl.origin}/api/arca/auth/callback?token=${token}`;

  const sent = await sendMagicLinkEmail(parsed.data.email, link);

  // No RESEND_API_KEY configured: hand the link back directly rather than
  // silently dropping it, the same "works with zero keys" posture as the
  // rest of this repo's demo-mode fallbacks. Never done in production, where
  // a caller who isn't the account owner could read someone else's link.
  const devLink =
    !sent && process.env.VERCEL_ENV !== "production" ? link : undefined;

  return NextResponse.json({ ok: true, ...(devLink ? { devLink } : {}) });
}

// Resend when configured, otherwise the owner's Gmail via Composio (see
// lib/mail/send.ts). Production had no RESEND_API_KEY, which used to make
// email sign-in silently return { ok: true } with no mail ever sent.
async function sendMagicLinkEmail(email: string, link: string): Promise<boolean> {
  return sendMail({
    to: email,
    subject: "Sign in to ARCA",
    html: `<p>Tap to sign in to ARCA. This link expires in 15 minutes.</p><p><a href="${link}">${link}</a></p><p style="color:#888;font-size:12px">If you didn't request this, ignore it.</p>`,
  });
}
