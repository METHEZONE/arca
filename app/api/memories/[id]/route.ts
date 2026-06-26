export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextRequest, NextResponse } from "next/server";
import type { ActionStatus } from "@/lib/types";
import type { Memory } from "@/lib/types";
import {
  getMemory,
  updateMemory,
  setActionItemStatus,
  deleteMemory,
} from "@/lib/secondbrain/store";

type RouteContext = { params: Promise<{ id: string }> };

export async function GET(
  _req: NextRequest,
  context: RouteContext
): Promise<NextResponse> {
  try {
    const { id } = await context.params;
    const memory = await getMemory(id);
    if (!memory) {
      return NextResponse.json({ error: "Memory not found" }, { status: 404 });
    }
    return NextResponse.json(memory);
  } catch (err: unknown) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}

export async function PATCH(
  req: NextRequest,
  context: RouteContext
): Promise<NextResponse> {
  try {
    const { id } = await context.params;
    const body = (await req.json()) as
      | { actionItemId: string; status: ActionStatus }
      | { tags: string[] }
      | { patch: Partial<Memory> };

    let updated: Memory | null = null;

    if ("actionItemId" in body && "status" in body) {
      updated = await setActionItemStatus(id, body.actionItemId, body.status);
    } else if ("tags" in body) {
      updated = await updateMemory(id, { tags: body.tags });
    } else if ("patch" in body) {
      updated = await updateMemory(id, body.patch);
    } else {
      return NextResponse.json({ error: "Invalid request body" }, { status: 400 });
    }

    if (!updated) {
      return NextResponse.json({ error: "Memory not found" }, { status: 404 });
    }
    return NextResponse.json(updated);
  } catch (err: unknown) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}

export async function DELETE(
  _req: NextRequest,
  context: RouteContext
): Promise<NextResponse> {
  try {
    const { id } = await context.params;
    const deleted = await deleteMemory(id);
    if (!deleted) {
      return NextResponse.json({ error: "Memory not found" }, { status: 404 });
    }
    return NextResponse.json({ ok: true });
  } catch (err: unknown) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
