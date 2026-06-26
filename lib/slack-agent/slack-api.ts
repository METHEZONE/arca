import { slackAgentDryRun, slackBotToken } from "@/lib/config";

import type { SlackPostResult } from "./types";

interface SlackPostMessageResponse {
  ok: boolean;
  error?: string;
  ts?: string;
}

export async function postSlackMessage(params: {
  channel: string;
  text: string;
  threadTs?: string;
}): Promise<SlackPostResult> {
  if (slackAgentDryRun()) {
    return { ok: true, detail: "dry-run: skipped chat.postMessage" };
  }

  const token = slackBotToken();
  if (!token) {
    return { ok: false, detail: "missing SLACK_BOT_TOKEN" };
  }

  const res = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify({
      channel: params.channel,
      text: params.text,
      thread_ts: params.threadTs,
    }),
  });

  const data = (await res.json()) as SlackPostMessageResponse;
  if (!data.ok) {
    return { ok: false, detail: data.error ?? `Slack API HTTP ${res.status}` };
  }

  return { ok: true, detail: "posted via chat.postMessage", ts: data.ts };
}
