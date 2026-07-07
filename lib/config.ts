// Centralized environment + capability resolution for ARCA.
// All env reads happen here so the rest of the app can ask "is X configured?"
// without scattering process.env across the codebase.

import type {
  Capabilities,
  Capability,
  IntegrationTarget,
} from "@/lib/types";

function env(name: string): string | undefined {
  const v = process.env[name];
  return v && v.trim().length > 0 ? v.trim() : undefined;
}

/* ----------------------------- Transcription ----------------------------- */

export type TranscriptionProvider = "auto" | "openai" | "elevenlabs" | "demo";

export function transcriptionProvider(): TranscriptionProvider {
  const forced = env("TRANSCRIPTION_PROVIDER")?.toLowerCase();
  if (
    forced === "auto" ||
    forced === "openai" ||
    forced === "elevenlabs" ||
    forced === "demo"
  ) {
    return forced;
  }
  return "auto";
}

export function elevenLabsKey(): string | undefined {
  return env("ELEVENLABS_API_KEY");
}

export function elevenLabsModel(): string {
  return env("ELEVENLABS_STT_MODEL") ?? "scribe_v2";
}

export function openAiTranscriptionModel(): string {
  return env("OPENAI_TRANSCRIPTION_MODEL") ?? "gpt-4o-transcribe-diarize";
}

/* ------------------------------- Analysis -------------------------------- */

export function anthropicKey(): string | undefined {
  return env("ANTHROPIC_API_KEY");
}

export function openAiKey(): string | undefined {
  return env("OPENAI_API_KEY");
}

export function claudeModel(): string {
  return env("ANTHROPIC_MODEL") ?? "claude-sonnet-4-6";
}

export function openAiNotesModel(): string {
  return env("OPENAI_NOTES_MODEL") ?? "gpt-5.5";
}

export type AnalysisProvider = "claude" | "openai" | "demo";

/** Which LLM analyzes transcripts. Env can force a provider; otherwise prefer
 *  Claude, then OpenAI, then demo. */
export function analysisProvider(): AnalysisProvider {
  const forced = env("ANALYSIS_PROVIDER")?.toLowerCase();
  if (forced === "claude") return anthropicKey() ? "claude" : "demo";
  if (forced === "openai") return openAiKey() ? "openai" : "demo";
  if (anthropicKey()) return "claude";
  if (openAiKey()) return "openai";
  return "demo";
}

/* ----------------------------- Integrations ------------------------------ */

export function obsidianVaultPath(): string | undefined {
  return env("OBSIDIAN_VAULT_PATH");
}

/** Sub-folder inside the vault where ARCA writes notes. */
export function obsidianSubfolder(): string {
  return env("OBSIDIAN_SUBFOLDER") ?? "ARCA";
}

export function notionKey(): string | undefined {
  return env("NOTION_API_KEY");
}

export function notionDatabaseId(): string | undefined {
  return env("NOTION_DATABASE_ID");
}

export function slackWebhookUrl(): string | undefined {
  return env("SLACK_WEBHOOK_URL");
}

export function slackBotToken(): string | undefined {
  return env("SLACK_BOT_TOKEN");
}

export function slackChannel(): string | undefined {
  return env("SLACK_CHANNEL");
}

export function slackSigningSecret(): string | undefined {
  return env("SLACK_SIGNING_SECRET");
}

export function slackAppBotUserId(): string | undefined {
  return env("SLACK_APP_BOT_USER_ID");
}

export function slackAgentOwnerUserId(): string | undefined {
  return env("SLACK_AGENT_OWNER_USER_ID");
}

export function slackAgentDefaultChannel(): string | undefined {
  return env("SLACK_AGENT_DEFAULT_CHANNEL") ?? env("SLACK_CHANNEL");
}

export function slackAgentDryRun(): boolean {
  return env("SLACK_AGENT_DRY_RUN") !== "false";
}

export function slackAgentAutoReply(): boolean {
  return env("SLACK_AGENT_AUTO_REPLY") === "true";
}

export function slackAgentRequireApproval(): boolean {
  return env("SLACK_AGENT_REQUIRE_APPROVAL") !== "false";
}

export function slackAgentModelTimeoutMs(): number {
  const raw = Number(env("SLACK_AGENT_MODEL_TIMEOUT_MS") ?? "1500");
  return Number.isFinite(raw) && raw > 0 ? raw : 1500;
}

export function slackAgentMentionChannels(): string[] {
  return (env("SLACK_AGENT_MENTION_CHANNELS") ?? "")
    .split(",")
    .map((channel) => channel.trim())
    .filter(Boolean);
}

export function integrationConfigured(target: IntegrationTarget): boolean {
  switch (target) {
    case "obsidian":
      return Boolean(obsidianVaultPath());
    case "notion":
      return Boolean(notionKey() && notionDatabaseId());
    case "slack":
      return Boolean(slackWebhookUrl() || (slackBotToken() && slackChannel()));
  }
}

/** Targets to push to automatically after each recording is processed.
 *  `AUTO_PUSH_TARGETS=obsidian,notion,slack`. Defaults to every configured
 *  target so the "it just lands in our shared space" promise holds out of the box. */
export function autoPushTargets(): IntegrationTarget[] {
  const raw = env("AUTO_PUSH_TARGETS");
  const all: IntegrationTarget[] = ["obsidian", "notion", "slack"];
  if (!raw) return all.filter(integrationConfigured);
  if (raw.toLowerCase() === "none") return [];
  const requested = raw
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s): s is IntegrationTarget => all.includes(s as IntegrationTarget));
  return requested.filter(integrationConfigured);
}

/* ------------------------------ Storage ---------------------------------- */

export function dataDir(): string {
  return env("ARCA_DATA_DIR") ?? "data";
}

/* ----------------------------- Hardware --------------------------------- */

export function hardwareIngestToken(): string | undefined {
  return env("ARCA_INGEST_TOKEN");
}

/* ----------------------------- Capabilities ------------------------------ */

export function capabilities(): Capabilities {
  const provider = analysisProvider();
  const items: Capability[] = [
    {
      key: "hardware",
      label: "Hardware ingest",
      configured: true,
      provider: hardwareIngestToken() ? "token protected" : "local open",
      detail: hardwareIngestToken()
        ? "ARCA hardware can upload recordings with x-arca-device-token."
        : "POST recordings to /api/hardware/ingest. Set ARCA_INGEST_TOKEN before exposing the app.",
    },
    {
      key: "transcription",
      label: "Transcription + Speakers",
      configured: Boolean(openAiKey() || elevenLabsKey()),
      provider:
        transcriptionProvider() === "demo"
          ? "Demo"
          : openAiKey()
            ? `OpenAI ${openAiTranscriptionModel()}`
            : elevenLabsKey()
              ? `ElevenLabs ${elevenLabsModel()}`
              : undefined,
      detail:
        openAiKey() || elevenLabsKey()
          ? "Speaker-diarized transcripts with provider fallback."
          : "Set OPENAI_API_KEY or ELEVENLABS_API_KEY for real diarized transcripts.",
    },
    {
      key: "analysis",
      label: "Notes & Action Plans",
      configured: provider !== "demo",
      provider:
        provider === "claude"
          ? `Claude ${claudeModel()}`
          : provider === "openai"
            ? `OpenAI ${openAiNotesModel()}`
            : undefined,
      detail:
        provider !== "demo"
          ? "Summaries, decisions, and grounded action items."
          : "Set ANTHROPIC_API_KEY or OPENAI_API_KEY to generate real notes.",
    },
    {
      key: "obsidian",
      label: "Obsidian Connector",
      configured: integrationConfigured("obsidian"),
      detail: integrationConfigured("obsidian")
        ? `Writes markdown to ${obsidianVaultPath()}/${obsidianSubfolder()}`
        : "Set OBSIDIAN_VAULT_PATH to sync notes into a vault.",
    },
    {
      key: "notion",
      label: "Notion Connector",
      configured: integrationConfigured("notion"),
      detail: integrationConfigured("notion")
        ? "Creates a page per memory in the shared database."
        : "Set NOTION_API_KEY and NOTION_DATABASE_ID.",
    },
    {
      key: "slack",
      label: "Slack Connector",
      configured: integrationConfigured("slack"),
      detail: integrationConfigured("slack")
        ? "Posts a summary + action items to the configured workspace."
        : "Set SLACK_WEBHOOK_URL (or SLACK_BOT_TOKEN + SLACK_CHANNEL).",
    },
  ];

  return {
    demoMode: provider === "demo" && !(openAiKey() || elevenLabsKey()),
    analysisProvider: provider,
    autoPushTargets: autoPushTargets(),
    items,
  };
}
