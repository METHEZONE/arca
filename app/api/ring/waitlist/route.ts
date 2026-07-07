export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { z } from "zod";
import { recordWaitlist, newRingId } from "@/lib/ring/store";

const BodySchema = z.object({
  email: z.string().trim().email().max(200),
  name: z.string().trim().max(120).optional(),
  source: z.string().trim().max(100).optional(),
  company_website: z.string().optional(), // honeypot
});

// Public form intake — also called cross-origin from thezonebio.com/arcaconnect.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export async function OPTIONS(): Promise<NextResponse> {
  return new NextResponse(null, { status: 204, headers: CORS });
}

export async function POST(req: Request): Promise<NextResponse> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, error: "invalid json" }, { status: 400, headers: CORS });
  }

  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ ok: false, error: "invalid email" }, { status: 400, headers: CORS });
  }
  if (parsed.data.company_website) {
    return NextResponse.json({ ok: true }, { headers: CORS });
  }

  const delivered = await recordWaitlist({
    id: newRingId(),
    email: parsed.data.email,
    name: parsed.data.name || undefined,
    source: parsed.data.source || "ring",
    createdAt: new Date().toISOString(),
  });

  return NextResponse.json({ ok: true, delivered }, { headers: CORS });
}
