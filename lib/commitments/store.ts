/**
 * Commitment loop persistence + the bounded execution engine.
 *
 * The model proposes (extraction, drafts); this file owns state transitions.
 * Nothing here ever advances a node past a human gate or fabricates external
 * evidence — `send`/`wait`/`outcome` nodes block until the user attaches
 * evidence (Gmail/Calendar adapters are "Coming next").
 */

import { and, asc, desc, eq, sql } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { commitmentNodes, commitments, feedbackEvents, profiles } from "@/lib/db/schema";
import { draftArtifact, type Extraction } from "./llm";
import { ensureCommitmentSchema } from "./schema-bootstrap";

export type NodeStatus = "pending" | "running" | "needs_approval" | "blocked" | "done" | "locked" | "rejected";

export type NodeRow = typeof commitmentNodes.$inferSelect;
export type CommitmentRow = typeof commitments.$inferSelect;
export type CommitmentDetail = CommitmentRow & { nodes: NodeRow[] };

function need() {
  const database = db();
  if (!database) throw new Error("DATABASE_URL is not set.");
  return database;
}

async function ready() {
  await ensureCommitmentSchema();
  return need();
}

export async function listCommitments(userId: string): Promise<CommitmentDetail[]> {
  const database = await ready();
  const rows = await database
    .select()
    .from(commitments)
    .where(eq(commitments.userId, userId))
    .orderBy(desc(commitments.createdAt))
    .limit(50);
  if (rows.length === 0) return [];
  const nodes = await database
    .select()
    .from(commitmentNodes)
    .where(sql`${commitmentNodes.commitmentId} in ${rows.map((r) => r.id)}`)
    .orderBy(asc(commitmentNodes.position));
  return rows.map((r) => ({ ...r, nodes: nodes.filter((n) => n.commitmentId === r.id) }));
}

export async function getCommitment(userId: string, id: string): Promise<CommitmentDetail | null> {
  const database = await ready();
  const [row] = await database
    .select()
    .from(commitments)
    .where(and(eq(commitments.id, id), eq(commitments.userId, userId)))
    .limit(1);
  if (!row) return null;
  const nodes = await database
    .select()
    .from(commitmentNodes)
    .where(eq(commitmentNodes.commitmentId, id))
    .orderBy(asc(commitmentNodes.position));
  return { ...row, nodes };
}

export async function createFromExtraction(
  userId: string,
  extraction: Extraction,
  source: { kind: "text" | "recording"; transcript: string },
): Promise<string[]> {
  const database = await ready();
  const ids: string[] = [];
  for (const c of extraction.commitments) {
    const [row] = await database
      .insert(commitments)
      .values({
        userId,
        title: c.title,
        counterpart: c.counterpart,
        due: c.due,
        outcome: c.outcome,
        sourceQuote: c.sourceQuote,
        sourceKind: source.kind,
        sourceSummary: extraction.summary,
        sourceTranscript: source.transcript.slice(0, 20000),
        status: "detected",
      })
      .returning({ id: commitments.id });
    // Guarantee start/outcome bookends regardless of what the model returned.
    const nodes = [...c.nodes];
    if (nodes[0]?.kind !== "start") nodes.unshift({ title: "약속 발생", kind: "start", risky: false, question: null });
    if (nodes[nodes.length - 1]?.kind !== "outcome") nodes.push({ title: c.outcome.slice(0, 18), kind: "outcome", risky: false, question: null });
    await database.insert(commitmentNodes).values(
      nodes.map((n, i) => ({
        commitmentId: row.id,
        position: i,
        title: n.title,
        kind: n.kind,
        // Only steps ARCA would *act* on can be boundary questions. The
        // promise itself, the human approve gate and the outcome never are.
        risky: n.kind === "decision" ? true : ["draft", "send", "wait"].includes(n.kind) ? n.risky : false,
        question: n.question,
        status: "pending",
      })),
    );
    ids.push(row.id);
  }
  return ids;
}

async function touch(id: string, patch: Partial<typeof commitments.$inferInsert>) {
  await (await ready())
    .update(commitments)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(commitments.id, id));
}

async function patchNode(nodeId: string, patch: Partial<typeof commitmentNodes.$inferInsert>) {
  await (await ready())
    .update(commitmentNodes)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(commitmentNodes.id, nodeId));
}

/** "ARCA it?" → yes. */
export async function acceptCommitment(userId: string, id: string): Promise<CommitmentDetail | null> {
  const c = await getCommitment(userId, id);
  if (!c) return null;
  if (c.status === "detected" || c.status === "proposed") await touch(id, { status: "accepted" });
  return getCommitment(userId, id);
}

/** Drag-bounded scope: inclusive node positions. Authorizes the commitment. */
export async function setScope(userId: string, id: string, start: number, end: number): Promise<CommitmentDetail | null> {
  const c = await getCommitment(userId, id);
  if (!c) return null;
  const max = c.nodes.length - 1;
  const s = Math.max(0, Math.min(start, end, max));
  const e = Math.min(max, Math.max(start, end, 0));
  await touch(id, { scopeStart: s, scopeEnd: e, status: c.status === "verified" ? "verified" : "authorized" });
  return getCommitment(userId, id);
}

export type RunEvent = { position: number; status: NodeStatus; note: string };

/**
 * Walks the graph in order and advances until the first human gate,
 * boundary, or missing external evidence. Deterministic; the only model
 * call is drafting the artifact of a `draft` node.
 */
export async function runCommitment(userId: string, id: string): Promise<{ detail: CommitmentDetail | null; events: RunEvent[] }> {
  const c = await getCommitment(userId, id);
  const events: RunEvent[] = [];
  if (!c) return { detail: null, events };
  if (c.scopeStart === null || c.scopeEnd === null) {
    return { detail: c, events: [{ position: -1, status: "blocked", note: "위임 범위를 먼저 드래그해 주세요." }] };
  }
  const database = await ready();
  const [profile] = await database.select().from(profiles).where(eq(profiles.userId, userId)).limit(1);

  if (c.status === "accepted" || c.status === "authorized") await touch(id, { status: "in_progress" });

  for (const node of c.nodes) {
    if (node.status === "done" || node.status === "locked") continue;
    if (node.status === "rejected") {
      events.push({ position: node.position, status: "rejected", note: "거절된 단계입니다. 수정 후 다시 실행하세요." });
      break;
    }
    const inScope = node.position >= c.scopeStart && node.position <= c.scopeEnd;

    if (node.kind === "start") {
      await patchNode(node.id, {
        status: "locked",
        evidence: c.sourceQuote ?? "대화에서 감지",
        evidenceKind: "transcript",
        evidenceAt: new Date(),
      });
      events.push({ position: node.position, status: "locked", note: "대화 원문이 증거로 잠김" });
      continue;
    }

    if (!inScope) {
      await patchNode(node.id, {
        status: "needs_approval",
        question: node.question ?? "이 단계는 위임 범위 밖입니다. ARCA가 이어서 진행할까요?",
      });
      events.push({ position: node.position, status: "needs_approval", note: "범위 밖 · ARCA가 먼저 묻습니다" });
      break;
    }

    if (node.risky || node.kind === "decision") {
      await patchNode(node.id, { status: "needs_approval", question: node.question ?? "이 판단을 진행해도 될까요?" });
      events.push({ position: node.position, status: "needs_approval", note: "경계 질문" });
      break;
    }

    if (node.kind === "draft") {
      await patchNode(node.id, { status: "running" });
      events.push({ position: node.position, status: "running", note: "초안 작성 중" });
      const drafted = await draftArtifact({
        nodeTitle: node.title,
        commitmentTitle: c.title,
        counterpart: c.counterpart,
        due: c.due,
        outcome: c.outcome,
        sourceQuote: c.sourceQuote,
        summary: c.sourceSummary,
        profile: profile ? { displayName: profile.displayName, company: profile.company, headline: profile.headline } : null,
      });
      await patchNode(node.id, {
        status: "needs_approval",
        artifact: drafted.text,
        question: drafted.provider === "demo" ? "모델 키 없이 만든 데모 초안입니다. 이대로 진행할까요?" : "이 초안으로 진행할까요?",
      });
      events.push({ position: node.position, status: "needs_approval", note: `초안 완료 (${drafted.provider}) · 승인 대기` });
      break;
    }

    if (node.kind === "approve") {
      await patchNode(node.id, { status: "needs_approval", question: node.question ?? "검토 후 승인해 주세요." });
      events.push({ position: node.position, status: "needs_approval", note: "사용자 승인 게이트" });
      break;
    }

    // send / wait / outcome: external world. No connector yet → block honestly.
    const note =
      node.kind === "send"
        ? "발송은 Gmail 연결 후 · Coming next. 직접 보냈다면 증거를 붙여넣어 잠글 수 있습니다."
        : node.kind === "wait"
          ? "상대의 회신·수락 같은 외부 증거가 필요합니다. 도착하면 붙여넣어 주세요."
          : "목표 결과의 외부 증거(회신·입금·캘린더 수락 등)가 있어야 verified로 닫힙니다.";
    await patchNode(node.id, { status: "blocked", question: note });
    events.push({ position: node.position, status: "blocked", note });
    break;
  }

  return { detail: await refreshStatus(userId, id), events };
}

/** Recomputes the Promise Packet status from node states. */
async function refreshStatus(userId: string, id: string): Promise<CommitmentDetail | null> {
  const c = await getCommitment(userId, id);
  if (!c) return null;
  const last = c.nodes[c.nodes.length - 1];
  let status = c.status;
  if (last?.status === "locked") status = "verified";
  else if (c.nodes.some((n) => n.status === "locked" && n.kind !== "start")) status = "evidence_submitted";
  else if (c.scopeStart !== null && c.nodes.some((n) => n.status !== "pending")) status = "in_progress";
  if (status !== c.status) {
    await touch(id, { status });
    return getCommitment(userId, id);
  }
  return c;
}

export type NodeAction =
  | { type: "approve" }
  | { type: "edit"; artifact: string }
  | { type: "reject"; note?: string }
  | { type: "evidence"; text: string; kind: "reply" | "url" | "calendar" | "payment" | "delivery" | "other" };

export async function actOnNode(userId: string, id: string, nodeId: string, action: NodeAction): Promise<CommitmentDetail | null> {
  const c = await getCommitment(userId, id);
  if (!c) return null;
  const node = c.nodes.find((n) => n.id === nodeId);
  if (!node) return c;

  if (action.type === "approve") {
    const outside = c.scopeStart === null || c.scopeEnd === null || node.position < c.scopeStart || node.position > c.scopeEnd;
    if (outside) {
      // "Yes, keep going" on a boundary node = the user just extended the
      // delegation scope to include it. Persist that, then let the run
      // handle the node by its kind (evidence nodes still need evidence).
      const s = c.scopeStart === null ? node.position : Math.min(c.scopeStart, node.position);
      const e = c.scopeEnd === null ? node.position : Math.max(c.scopeEnd, node.position);
      await touch(id, { scopeStart: s, scopeEnd: e });
      await patchNode(node.id, { status: "pending", risky: false, question: null });
      return refreshStatus(userId, id);
    }
    if (node.kind === "wait" || node.kind === "outcome") {
      // Approval never substitutes for external evidence.
      await patchNode(node.id, { status: "pending", risky: false, question: null });
      return refreshStatus(userId, id);
    }
    if (node.kind === "draft" && !node.artifact) {
      // Boundary question answered "yes" → ARCA may now draft. The draft
      // itself still comes back for approval before anything moves on.
      await patchNode(node.id, { status: "pending", risky: false, question: null });
      return refreshStatus(userId, id);
    }
    if (node.kind === "send" && node.status === "needs_approval") {
      // Approved to send, but no connector exists yet → block honestly.
      await patchNode(node.id, { status: "pending", risky: false, question: null });
      return refreshStatus(userId, id);
    }
    await patchNode(node.id, { status: "done", question: null });
    // Approving a draft also satisfies an immediately following approve gate.
    const next = c.nodes.find((n) => n.position === node.position + 1);
    if (node.kind === "draft" && next?.kind === "approve") await patchNode(next.id, { status: "done" });
  } else if (action.type === "edit") {
    await patchNode(node.id, { artifact: action.artifact.slice(0, 20000), status: "needs_approval" });
  } else if (action.type === "reject") {
    await patchNode(node.id, { status: "rejected" });
  } else if (action.type === "evidence") {
    await patchNode(node.id, {
      status: "locked",
      evidence: action.text.slice(0, 4000),
      evidenceKind: action.kind,
      evidenceAt: new Date(),
      question: null,
    });
  }
  return refreshStatus(userId, id);
}

export type Rail = "consent" | "quality";

export async function addFeedback(userId: string, input: { commitmentId?: string; nodeId?: string; rail: Rail; value: string; note?: string }) {
  await (await ready()).insert(feedbackEvents).values({
    userId,
    commitmentId: input.commitmentId,
    nodeId: input.nodeId,
    rail: input.rail,
    value: input.value.slice(0, 80),
    note: input.note?.slice(0, 500),
  });
}

export type TasteModel = { consent: Record<string, number>; quality: Record<string, number>; total: number };

export async function tasteModel(userId: string): Promise<TasteModel> {
  const rows = await (await ready())
    .select({ rail: feedbackEvents.rail, value: feedbackEvents.value, n: sql<number>`count(*)::int` })
    .from(feedbackEvents)
    .where(eq(feedbackEvents.userId, userId))
    .groupBy(feedbackEvents.rail, feedbackEvents.value);
  const out: TasteModel = { consent: {}, quality: {}, total: 0 };
  for (const r of rows) {
    const rail = r.rail === "consent" ? out.consent : out.quality;
    rail[r.value] = (rail[r.value] ?? 0) + r.n;
    out.total += r.n;
  }
  return out;
}

export async function deleteCommitment(userId: string, id: string): Promise<boolean> {
  const c = await getCommitment(userId, id);
  if (!c) return false;
  const database = await ready();
  await database.delete(feedbackEvents).where(eq(feedbackEvents.commitmentId, id));
  await database.delete(commitmentNodes).where(eq(commitmentNodes.commitmentId, id));
  await database.delete(commitments).where(eq(commitments.id, id));
  return true;
}
