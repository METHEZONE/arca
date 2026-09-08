/**
 * Owner notification for ARCA Core recordings.
 *
 * On Vercel the memory store is /tmp, which forgets everything on the next cold
 * start, so a finished recording is mailed to the owner the moment it is
 * analyzed. No new credentials: the Composio project key is already in the
 * environment and the owner's Gmail is already connected under
 * ARCA_HARDWARE_MAIL_USER (the same connection the Mac app uses).
 *
 * ponytail: transcript + notes in the body, no audio attachment. The WAV stays
 * on the card in /arca/uploaded. Add Composio's presigned upload when audio in
 * the mail matters.
 */

import type { Memory } from "@/lib/types";

const COMPOSIO = "https://backend.composio.dev/api/v3";

type Account = { id: string; status: string; toolkit?: { slug?: string } };

function label(item: unknown): string {
  if (typeof item === "string") return item;
  const o = item as { title?: string; text?: string; description?: string; task?: string };
  return o.title ?? o.text ?? o.task ?? o.description ?? JSON.stringify(item);
}

function mmss(sec: number): string {
  const m = Math.floor(sec / 60), s = Math.round(sec % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}

function section(title: string, items: unknown[]): string {
  if (!items?.length) return "";
  return `\n${title}\n${items.map((i) => `- ${label(i)}`).join("\n")}\n`;
}

export function subjectFor(memory: Memory): string {
  return `ARCA Core · ${memory.analysis.title || "recording"} · ${mmss(memory.durationSec)}`;
}

export function bodyFor(memory: Memory): string {
  const a = memory.analysis;
  const when = new Date(memory.createdAt).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" });
  const device = memory.tags.find((t) => t.startsWith("device:"))?.slice(7) ?? "arca-core";
  const incomplete = memory.tags.find((t) => t.startsWith("incomplete:"));
  return [
    `${when} · ${mmss(memory.durationSec)} · ${device}`,
    incomplete ? `⚠ ${incomplete.replace(":", " ")} chunk(s) never arrived` : "",
    a.warning ? `⚠ ${a.warning}` : "",
    memory.transcript.warning ? `⚠ ${memory.transcript.warning}` : "",
    "",
    a.summary,
    section("하이라이트", a.highlights),
    section("결정", a.decisions),
    section("할 일", a.actionItems),
    section("열린 질문", a.openQuestions),
    "\n— 전사 —",
    memory.transcript.fullText || "(empty)",
  ].filter((l) => l !== "").join("\n");
}

export function hardwareMailConfigured(): boolean {
  return Boolean(process.env.COMPOSIO_API_KEY && process.env.ARCA_HARDWARE_MAIL_USER && process.env.ARCA_HARDWARE_MAIL_TO);
}

/** Mail the finished memory to the owner. Throws on failure; callers decide. */
export async function mailOwner(memory: Memory): Promise<void> {
  const key = process.env.COMPOSIO_API_KEY?.trim();
  const userId = process.env.ARCA_HARDWARE_MAIL_USER?.trim();
  const to = process.env.ARCA_HARDWARE_MAIL_TO?.trim();
  if (!key || !userId || !to) return;

  const headers = { "x-api-key": key, "content-type": "application/json" };
  const listed = await fetch(`${COMPOSIO}/connected_accounts?user_ids=${encodeURIComponent(userId)}`, { headers });
  const { items = [] } = (await listed.json()) as { items?: Account[] };
  const gmail = items.find((a) => a.toolkit?.slug === "gmail" && a.status === "ACTIVE");
  if (!gmail) throw new Error(`no active Gmail connection for ${userId}`);

  const res = await fetch(`${COMPOSIO}/tools/execute/GMAIL_SEND_EMAIL`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      user_id: userId,
      connected_account_id: gmail.id,
      arguments: { recipient_email: to, subject: subjectFor(memory), body: bodyFor(memory), is_html: false },
    }),
  });
  const out = (await res.json().catch(() => ({}))) as { successful?: boolean; error?: string | null };
  if (!res.ok || out.successful === false) throw new Error(out.error ?? `composio ${res.status}`);
}
