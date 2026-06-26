export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import type { IntegrationTarget } from "@/lib/types";
import { getMemory, updateMemory } from "@/lib/secondbrain/store";
import { pushToTargets } from "@/lib/integrations";

const VALID_TARGETS = new Set<string>(["obsidian", "notion", "slack"]);

function isIntegrationTarget(v: unknown): v is IntegrationTarget {
  return typeof v === "string" && VALID_TARGETS.has(v);
}

export async function POST(req: Request): Promise<NextResponse> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }

  if (
    typeof body !== "object" ||
    body === null ||
    !("memoryId" in body) ||
    !("targets" in body)
  ) {
    return NextResponse.json(
      { error: "Body must be { memoryId: string; targets: IntegrationTarget[] }." },
      { status: 400 },
    );
  }

  const { memoryId, targets } = body as Record<string, unknown>;

  if (typeof memoryId !== "string" || !memoryId) {
    return NextResponse.json({ error: "memoryId must be a non-empty string." }, { status: 400 });
  }

  if (!Array.isArray(targets) || !targets.every(isIntegrationTarget)) {
    return NextResponse.json(
      { error: "targets must be an array of 'obsidian' | 'notion' | 'slack'." },
      { status: 400 },
    );
  }

  const memory = await getMemory(memoryId);
  if (!memory) {
    return NextResponse.json({ error: `Memory "${memoryId}" not found.` }, { status: 404 });
  }

  const results = await pushToTargets(memory, targets);

  // Merge results: replace existing entries for same target, append new ones.
  const existing = memory.integrations ?? [];
  const merged = [
    ...existing.filter((r) => !results.some((nr) => nr.target === r.target)),
    ...results,
  ];

  const updatedMemory = await updateMemory(memoryId, { integrations: merged });

  return NextResponse.json({ results, memory: updatedMemory });
}
