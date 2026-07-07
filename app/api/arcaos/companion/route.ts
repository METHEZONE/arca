// POST /api/arcaos/companion — hatch a companion persona.
// Body: { profile: CompanyProfile, salt?: number, name?: string }
// Returns the deterministic CompanionSpec plus a persona written live by
// Claude when a key is configured, or the demo persona otherwise.

import { NextRequest, NextResponse } from "next/server";

import { generateCompanion, makeGreeting, sanitizeProfile } from "@/lib/companion/generate";
import { hatchPersona } from "@/lib/companion/persona";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }

  const { profile: rawProfile, salt, name } = (body ?? {}) as {
    profile?: unknown;
    salt?: unknown;
    name?: unknown;
  };
  const profile = sanitizeProfile(rawProfile);
  if (!profile) {
    return NextResponse.json({ error: "Invalid or incomplete profile." }, { status: 400 });
  }

  let spec = generateCompanion(profile, typeof salt === "number" ? salt : 0);
  if (typeof name === "string" && name.trim() && name.trim().length <= 12) {
    const picked = name.trim();
    spec = { ...spec, name: picked, greeting: makeGreeting(profile.tone, profile.company, picked) };
  }
  const persona = await hatchPersona(profile, spec);

  return NextResponse.json({ spec, persona });
}
