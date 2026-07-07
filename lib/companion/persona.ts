// Live persona layer for a freshly hatched companion.
// With ANTHROPIC_API_KEY, Claude writes the greeting/note/tip in the team's
// chosen tone; without it (or on any failure) the deterministic demo persona
// from generate.ts answers instead — the hatch never blocks on a key.

import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod";

import { anthropicKey, claudeModel } from "@/lib/config";
import {
  type CompanionSpec,
  type CompanyProfile,
  FOCUS_LABELS,
  INDUSTRIES,
  PACE_LABELS,
  TONE_LABELS,
  TOOL_LABELS,
} from "@/lib/companion/generate";

export interface CompanionPersona {
  provider: "claude" | "demo";
  greeting: string;
  note: string;
  tip: string;
  warning?: string;
}

const personaSchema = z.object({
  greeting: z
    .string()
    .describe("첫 인사. 회사 이름과 자기 이름을 넣어 1-2문장, 지정된 말투로."),
  note: z
    .string()
    .describe("자기 성격을 스스로 소개하는 한 문장. 아키타입과 특성을 자연스럽게 녹일 것."),
  tip: z
    .string()
    .describe("이 팀의 업종·도구·몰입 시간에 맞춘 구체적인 위임 팁 한 문장."),
});

const PERSONA_SYSTEM = [
  "You are a freshly hatched ARCA companion — a flow-state guardian that will",
  "protect one team's deep-focus ZONE by triaging interruptions for them.",
  "You were just generated from the team's onboarding answers, and you speak",
  "Korean, in the exact tone the team chose.",
  "",
  "Rules:",
  "- Stay in character as the companion itself (first person). Never mention AI, 모델, or prompts.",
  "- Match the requested tone precisely (깍듯한 존댓말 / 친근한 존댓말 / 짧고 담백하게).",
  "- Be specific to the team's context. No generic productivity phrases.",
  "- Keep each field within its length guidance. 한국어로만 답한다.",
].join("\n");

function buildUserContent(profile: CompanyProfile, spec: CompanionSpec): string {
  return [
    `회사/팀: ${profile.company}`,
    `업종: ${INDUSTRIES[profile.industry].label}`,
    `팀의 페이스: ${PACE_LABELS[profile.pace]}`,
    `말투: ${TONE_LABELS[profile.tone]}`,
    `지키고 싶은 몰입 시간: ${FOCUS_LABELS[profile.focus]}`,
    `연결한 도구: ${profile.tools.length ? profile.tools.map((t) => TOOL_LABELS[t]).join(", ") : "아직 없음"}`,
    "",
    `내 이름: ${spec.name}`,
    `내 아키타입: ${spec.archetype}`,
    `내 특성: ${spec.traits.join(", ")}`,
  ].join("\n");
}

function demoPersona(spec: CompanionSpec, warning?: string): CompanionPersona {
  return {
    provider: "demo",
    greeting: spec.greeting,
    note: `${spec.archetype} — ${spec.traits.join(" · ")} 을(를) 무기로 팀의 ZONE을 지킵니다.`,
    tip: `${spec.delegations[0]}부터 맡겨보세요. 잘 해내면 다음 위임이 쉬워집니다.`,
    warning,
  };
}

export async function hatchPersona(
  profile: CompanyProfile,
  spec: CompanionSpec,
): Promise<CompanionPersona> {
  if (!anthropicKey()) {
    return demoPersona(spec, "ANTHROPIC_API_KEY가 없어 기본 페르소나로 부화했습니다.");
  }

  try {
    const client = new Anthropic();
    const response = await client.messages.parse({
      model: claudeModel(),
      max_tokens: 1000,
      output_config: {
        format: zodOutputFormat(personaSchema),
        // The hatch moment is latency-sensitive; three short sentences don't
        // need deep reasoning.
        effort: "low",
      },
      system: PERSONA_SYSTEM,
      messages: [{ role: "user", content: buildUserContent(profile, spec) }],
    });

    const parsed = response.parsed_output;
    if (!parsed) throw new Error("Claude returned no parseable persona output.");
    return { provider: "claude", ...parsed };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return demoPersona(
      spec,
      `claude persona failed, so ARCA used the demo persona: ${message.slice(0, 200)}`,
    );
  }
}
