/**
 * LLM calls for the commitment loop. Claude first (structured output via
 * zodOutputFormat, same as lib/delegate/engine.ts), OpenAI second, and a
 * deterministic demo extractor when no key is present — the loop must never
 * pretend to work: demo results are flagged `provider: "demo"`.
 */

import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import OpenAI from "openai";
import { zodResponseFormat } from "openai/helpers/zod";
import { z } from "zod";

import { analysisProvider, claudeModel, openAiNotesModel } from "@/lib/config";

export const NODE_KINDS = ["start", "draft", "approve", "send", "wait", "decision", "outcome"] as const;
export type NodeKind = (typeof NODE_KINDS)[number];

const nodeSchema = z.object({
  title: z.string().describe("Short Korean label for the node, ≤ 18 chars."),
  kind: z.enum(NODE_KINDS),
  risky: z
    .boolean()
    .describe("true when this step needs the user's judgement even inside the delegated scope (money, price, commitments to third parties)."),
  question: z
    .string()
    .nullable()
    .describe("If risky: the exact short question ARCA should ask before acting. Otherwise null."),
});

const commitmentSchema = z.object({
  title: z.string().describe("The commitment in one short Korean sentence, as a promise."),
  counterpart: z.string().nullable().describe("Who the promise is to (name/role), or null."),
  due: z.string().nullable().describe("Due as stated (e.g. '금요일까지'), or null."),
  outcome: z.string().describe("The real-world result that proves it is done (e.g. '고객이 견적을 수락')."),
  sourceQuote: z.string().describe("Verbatim quote from the transcript that contains the promise."),
  nodes: z
    .array(nodeSchema)
    .min(3)
    .max(8)
    .describe("Ordered path from the start node (the promise itself) to the outcome node."),
});

export const extractionSchema = z.object({
  summary: z.string().describe("2–3 sentence Korean summary of the conversation."),
  commitments: z.array(commitmentSchema).max(6),
});

export type Extraction = z.infer<typeof extractionSchema> & { provider: "claude" | "openai" | "demo" };

const EXTRACT_SYSTEM = [
  "You are ARCA, a Personal Life OS that detects commitments (약속) in real conversations and turns each into a Commitment Graph.",
  "Given a meeting or chat transcript, extract ONLY commitments the speaker (the user) actually made or clearly accepted: things they said they would do for someone by some time.",
  "For each commitment build an ordered path of 3–8 nodes from the promise itself to the real-world outcome that proves completion.",
  "Node kinds: start (the promise), draft (ARCA can produce an artifact: email/message/document draft), approve (the user reviews the draft), send (the artifact goes to the counterpart), wait (waiting for the counterpart's reply or an external event), decision (a judgement call: price, scope, money, timing), outcome (the external evidence that closes it).",
  "The first node must be kind=start and the last node must be kind=outcome. Mark decision nodes and anything involving money, discounts, third-party commitments or deadlines as risky=true with a short question.",
  "Never invent people, amounts, dates or promises that are not in the transcript. If the transcript has no commitment, return an empty commitments array.",
  "Respond in Korean (titles, questions, summary), keep labels short.",
].join(" ");

export async function extractCommitments(transcript: string): Promise<Extraction> {
  const provider = analysisProvider();
  const text = transcript.slice(0, 24000);
  if (provider === "demo") return demoExtraction(text);
  try {
    if (provider === "claude") {
      const client = new Anthropic();
      const res = await client.messages.parse({
        model: claudeModel(),
        max_tokens: 4000,
        output_config: { format: zodOutputFormat(extractionSchema) },
        system: EXTRACT_SYSTEM,
        messages: [{ role: "user", content: `Transcript:\n${text}` }],
      });
      const parsed = res.parsed_output;
      if (!parsed) throw new Error("Claude returned no parseable output.");
      return { ...parsed, provider: "claude" };
    }
    const client = new OpenAI();
    const completion = await client.chat.completions.parse({
      model: openAiNotesModel(),
      messages: [
        { role: "system", content: EXTRACT_SYSTEM },
        { role: "user", content: `Transcript:\n${text}` },
      ],
      response_format: zodResponseFormat(extractionSchema, "arca_commitments"),
    });
    const parsed = completion.choices[0]?.message.parsed;
    if (!parsed) throw new Error("OpenAI returned no parseable output.");
    return { ...parsed, provider: "openai" };
  } catch (err) {
    const demo = demoExtraction(text);
    demo.summary = `${demo.summary} (모델 호출 실패로 데모 추출 사용: ${err instanceof Error ? err.message.slice(0, 120) : "unknown"})`;
    return demo;
  }
}

/** Keyword-only fallback: finds "~까지 ~할게요/드릴게요/보내" style promises. */
function demoExtraction(text: string): Extraction {
  const sentences = text.split(/(?<=[.!?。\n])\s*/).map((s) => s.trim()).filter(Boolean);
  const hits = sentences.filter((s) => /(드릴게요|드리겠습니다|할게요|하겠습니다|보내|공유|전달|확인해)/.test(s)).slice(0, 3);
  return {
    provider: "demo",
    summary: "모델 키가 없어 키워드 기반으로 약속 후보를 찾았습니다.",
    commitments: hits.map((q) => ({
      title: q.length > 40 ? `${q.slice(0, 40)}…` : q,
      counterpart: null,
      due: (q.match(/[가-힣0-9월일주]+까지/) ?? [null])[0],
      outcome: "상대가 받았다는 회신",
      sourceQuote: q,
      nodes: [
        { title: "약속 발생", kind: "start", risky: false, question: null },
        { title: "초안 작성", kind: "draft", risky: false, question: null },
        { title: "승인", kind: "approve", risky: false, question: null },
        { title: "발송", kind: "send", risky: false, question: null },
        { title: "회신 확인", kind: "outcome", risky: false, question: null },
      ],
    })),
  };
}

/* ------------------------------------------------------------------ *
 * Drafting an artifact for a `draft` node
 * ------------------------------------------------------------------ */

const DRAFT_SYSTEM = [
  "You are ARCA drafting on behalf of the user for one step of a commitment.",
  "Write the artifact (usually a short Korean email or message) that fulfils the node, grounded ONLY in the commitment, the source quote, the summary and the user's confirmed profile.",
  "Do not invent numbers, dates, prices or facts. Where something is unknown, leave a [확인] placeholder.",
  "Return only the artifact text, no preamble.",
].join(" ");

export async function draftArtifact(input: {
  nodeTitle: string;
  commitmentTitle: string;
  counterpart: string | null;
  due: string | null;
  outcome: string;
  sourceQuote: string | null;
  summary: string | null;
  profile: { displayName: string | null; company: string | null; headline: string | null } | null;
}): Promise<{ text: string; provider: "claude" | "openai" | "demo" }> {
  const provider = analysisProvider();
  const user = [
    `Node: ${input.nodeTitle}`,
    `Commitment: ${input.commitmentTitle}`,
    `Counterpart: ${input.counterpart ?? "(unknown)"}`,
    `Due: ${input.due ?? "(unstated)"}`,
    `Outcome that closes it: ${input.outcome}`,
    `Source quote: ${input.sourceQuote ?? "(none)"}`,
    `Conversation summary: ${input.summary ?? "(none)"}`,
    `Sender: ${input.profile?.displayName ?? "(user)"}${input.profile?.company ? ` · ${input.profile.company}` : ""}${input.profile?.headline ? ` · ${input.profile.headline}` : ""}`,
  ].join("\n");
  if (provider === "demo") {
    return { provider: "demo", text: demoDraft(input) };
  }
  try {
    if (provider === "claude") {
      const client = new Anthropic();
      const res = await client.messages.create({
        model: claudeModel(),
        max_tokens: 1200,
        system: DRAFT_SYSTEM,
        messages: [{ role: "user", content: user }],
      });
      const text = res.content.map((c) => (c.type === "text" ? c.text : "")).join("").trim();
      if (!text) throw new Error("empty");
      return { provider: "claude", text };
    }
    const client = new OpenAI();
    const completion = await client.chat.completions.create({
      model: openAiNotesModel(),
      messages: [
        { role: "system", content: DRAFT_SYSTEM },
        { role: "user", content: user },
      ],
    });
    const text = completion.choices[0]?.message.content?.trim();
    if (!text) throw new Error("empty");
    return { provider: "openai", text };
  } catch {
    return { provider: "demo", text: demoDraft(input) };
  }
}

function demoDraft(input: { commitmentTitle: string; counterpart: string | null; due: string | null; outcome: string }): string {
  return [
    `${input.counterpart ?? "[받는 분]"}님, 안녕하세요.`,
    "",
    `말씀드린 대로 ${input.commitmentTitle}${input.due ? ` (${input.due})` : ""} 관련해 정리해 드립니다.`,
    "[확인] 세부 내용",
    "",
    `확인 후 회신 주시면 ${input.outcome}까지 이어서 진행하겠습니다.`,
    "감사합니다.",
  ].join("\n");
}
