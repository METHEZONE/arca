import { slackWebhookUrl, slackBotToken, slackChannel } from "@/lib/config";
import { memoryToSlackText, memoryToSlackBlocks } from "@/lib/render";
import type { Memory, IntegrationResult } from "@/lib/types";

interface SlackApiResponse {
  ok: boolean;
  error?: string;
  ts?: string;
}

export async function pushToSlack(memory: Memory): Promise<IntegrationResult> {
  const at = new Date().toISOString();
  const webhookUrl = slackWebhookUrl();
  const botToken = slackBotToken();
  const channel = slackChannel();

  if (!webhookUrl && !(botToken && channel)) {
    return {
      target: "slack",
      status: "skipped",
      detail:
        "Set SLACK_WEBHOOK_URL (or SLACK_BOT_TOKEN + SLACK_CHANNEL).",
      at,
    };
  }

  const text = memoryToSlackText(memory);
  const blocks = memoryToSlackBlocks(memory);

  try {
    if (webhookUrl) {
      const res = await fetch(webhookUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, blocks }),
      });

      if (!res.ok) {
        const errText = await res.text();
        return {
          target: "slack",
          status: "error",
          detail: `slack webhook ${res.status}: ${errText.slice(0, 200)}`,
          at,
        };
      }

      // Slack webhooks return "ok" plain text on success
      await res.text();
      return {
        target: "slack",
        status: "success",
        detail: "posted via webhook",
        at,
      };
    }

    // Bot token + channel path (both are defined here due to the guard above)
    const res = await fetch("https://slack.com/api/chat.postMessage", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${botToken as string}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify({ channel: channel as string, text, blocks }),
    });

    const data = (await res.json()) as SlackApiResponse;

    if (!data.ok) {
      return {
        target: "slack",
        status: "error",
        detail: data.error ?? "unknown slack error",
        at,
      };
    }

    return {
      target: "slack",
      status: "success",
      detail: `posted to ${channel as string}`,
      at,
    };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      target: "slack",
      status: "error",
      detail: message,
      at,
    };
  }
}
