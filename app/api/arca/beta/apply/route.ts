export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { z } from "zod";
import { notifyOwner, recordWaitlist, newRingId } from "@/lib/ring/store";

const BodySchema = z.object({
  name: z.string().trim().min(1).max(80),
  email: z.string().trim().email().max(200),
  note: z.string().trim().max(600).optional(),
  platform: z.enum(["mac", "ios", "both"]).optional(),
  company_website: z.string().optional(), // honeypot
});

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export async function OPTIONS(): Promise<NextResponse> {
  return new NextResponse(null, { status: 204, headers: CORS });
}

// A beta application. No ledger: the owner is notified and approves from
// /arcadash by minting a signed download link for the applicant's email.
export async function POST(req: Request): Promise<NextResponse> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, error: "invalid json" }, { status: 400, headers: CORS });
  }
  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ ok: false, error: "invalid form" }, { status: 400, headers: CORS });
  }
  if (parsed.data.company_website) return NextResponse.json({ ok: true }, { headers: CORS });

  const { name, email, note, platform } = parsed.data;
  const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string));
  await recordWaitlist({ id: newRingId(), email, name, source: "arca-mac-beta", createdAt: new Date().toISOString() });
  const delivered = await notifyOwner(
    `ARCA 베타 신청 — ${name} <${email}>`,
    `<p><b>${esc(name)}</b> &lt;${esc(email)}&gt; · ${platform ?? "mac"}</p><p>${esc(note ?? "")}</p><p>승인: /arcadash 에서 이메일 입력 → 링크 생성 → 회신</p>`,
    `📥 ARCA 베타 신청 — ${name} <${email}> (${platform ?? "mac"})${note ? `\n${note}` : ""}\n승인은 /arcadash`
  );
  return NextResponse.json({ ok: true, delivered }, { headers: CORS });
}
