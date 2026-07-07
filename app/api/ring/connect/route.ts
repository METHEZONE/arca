export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { z } from "zod";
import { recordConnection, newRingId } from "@/lib/ring/store";
import { RING_DEFAULT_CATEGORY } from "@/lib/ring/profile";

const BodySchema = z.object({
  name: z.string().trim().min(1).max(120),
  phone: z.string().trim().max(40).optional(),
  email: z.string().trim().email().max(200).optional(),
  affiliation: z.string().trim().max(200).optional(),
  note: z.string().trim().max(1000).optional(),
  category: z.string().trim().max(100).optional(),
  location: z
    .object({
      lat: z.number().min(-90).max(90).optional(),
      lng: z.number().min(-180).max(180).optional(),
      label: z.string().trim().max(200).optional(),
    })
    .optional(),
  meetCount: z.number().int().min(1).max(1000).optional(),
  history: z
    .array(
      z.object({
        at: z.string().max(40),
        place: z.string().max(200).optional(),
      })
    )
    .max(50)
    .optional(),
  // Honeypot: real users never fill this.
  company_website: z.string().optional(),
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
    return NextResponse.json({ ok: false, error: "invalid fields" }, { status: 400, headers: CORS });
  }
  const d = parsed.data;

  if (d.company_website) {
    // Bot filled the honeypot — pretend success, record nothing.
    return NextResponse.json({ ok: true }, { headers: CORS });
  }
  if (!d.phone && !d.email) {
    return NextResponse.json(
      { ok: false, error: "phone or email required" },
      { status: 400, headers: CORS }
    );
  }

  const delivered = await recordConnection({
    id: newRingId(),
    name: d.name,
    phone: d.phone || undefined,
    email: d.email || undefined,
    affiliation: d.affiliation || undefined,
    note: d.note || undefined,
    category: d.category || RING_DEFAULT_CATEGORY,
    occurredAt: new Date().toISOString(),
    location: d.location,
    meetCount: d.meetCount ?? 1,
    history: d.history ?? [],
    userAgent: req.headers.get("user-agent") ?? undefined,
  });

  return NextResponse.json({ ok: true, delivered }, { headers: CORS });
}
