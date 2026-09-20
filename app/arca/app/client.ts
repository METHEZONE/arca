"use client";

import { arcaBase } from "@/lib/arca/origin";

export type Node = {
  id: string;
  commitmentId: string;
  position: number;
  title: string;
  kind: "start" | "draft" | "approve" | "send" | "wait" | "decision" | "outcome" | string;
  risky: boolean;
  question: string | null;
  status: "pending" | "running" | "needs_approval" | "blocked" | "done" | "locked" | "rejected" | string;
  artifact: string | null;
  evidence: string | null;
  evidenceKind: string | null;
  evidenceAt: string | null;
};

export type Commitment = {
  id: string;
  title: string;
  counterpart: string | null;
  due: string | null;
  outcome: string;
  sourceQuote: string | null;
  sourceKind: string;
  sourceSummary: string | null;
  status: "detected" | "proposed" | "accepted" | "authorized" | "in_progress" | "evidence_submitted" | "verified" | string;
  scopeStart: number | null;
  scopeEnd: number | null;
  createdAt: string;
  nodes: Node[];
};

export type Taste = { consent: Record<string, number>; quality: Record<string, number>; total: number };

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${arcaBase()}${path}`, {
    ...init,
    credentials: "include",
    headers: { ...(init?.body && !(init.body instanceof FormData) ? { "Content-Type": "application/json" } : {}), ...(init?.headers ?? {}) },
  });
  if (res.status === 401) {
    if (typeof window !== "undefined") window.location.href = `${arcaBase()}/arca/onboarding?next=app`;
    throw new ApiError(401, "Not signed in.");
  }
  const data = (await res.json().catch(() => ({}))) as { error?: string } & T;
  if (!res.ok) throw new ApiError(res.status, data.error ?? `HTTP ${res.status}`);
  return data;
}

export const STATUS_KO: Record<string, string> = {
  detected: "감지됨",
  proposed: "제안됨",
  accepted: "수락 · 범위 필요",
  authorized: "범위 설정됨",
  in_progress: "실행 중",
  evidence_submitted: "증거 일부",
  verified: "verified",
};

export const NODE_KIND_KO: Record<string, string> = {
  start: "약속",
  draft: "초안",
  approve: "승인",
  send: "발송",
  wait: "대기",
  decision: "판단",
  outcome: "결과",
};
