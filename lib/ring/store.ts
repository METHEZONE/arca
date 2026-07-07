// ARCA Ring — persistence + delivery for NFC connections and waitlist signups.
// Every submission is (1) appended to the file DB, (2) emailed to Min via
// Resend when RESEND_API_KEY is set, (3) posted to Slack when a webhook is set.
// On Vercel the file DB lives in /tmp (ephemeral), so email/Slack is the
// durable record there.

import { appendFile, mkdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { randomUUID } from "node:crypto";
import { dataDir, slackWebhookUrl } from "@/lib/config";

export type RingLocation = {
  lat?: number;
  lng?: number;
  label?: string;
};

export type RingMeeting = {
  at: string; // ISO timestamp
  place?: string;
};

export type RingConnection = {
  id: string;
  name: string;
  phone?: string;
  email?: string;
  affiliation?: string;
  note?: string;
  category: string;
  occurredAt: string;
  location?: RingLocation;
  meetCount: number;
  history: RingMeeting[];
  userAgent?: string;
};

export type WaitlistEntry = {
  id: string;
  email: string;
  name?: string;
  source: string;
  createdAt: string;
};

export type Delivery = { file: boolean; email: boolean; slack: boolean };

function ringDir(): string {
  const configured = dataDir();
  const base =
    process.env.VERCEL && !isAbsolute(configured)
      ? join("/tmp", configured)
      : isAbsolute(configured)
        ? configured
        : join(process.cwd(), configured);
  return join(base, "ring");
}

async function appendJsonl(file: string, record: unknown): Promise<boolean> {
  try {
    await mkdir(ringDir(), { recursive: true });
    await appendFile(join(ringDir(), file), JSON.stringify(record) + "\n", "utf-8");
    return true;
  } catch {
    return false;
  }
}

function notifyEmail(): string {
  return process.env.RING_NOTIFY_EMAIL?.trim() || "me@thezonebio.com";
}

async function sendEmail(subject: string, html: string): Promise<boolean> {
  const key = process.env.RESEND_API_KEY?.trim();
  if (!key) return sendViaFormSubmit(subject, html);
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: process.env.RING_FROM_EMAIL?.trim() || "ARCA Ring <onboarding@resend.dev>",
        to: [notifyEmail()],
        subject,
        html,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// No-signup fallback: formsubmit.co relays the payload to the notify inbox.
// The very first email triggers a one-time activation link — click it once.
async function sendViaFormSubmit(subject: string, html: string): Promise<boolean> {
  try {
    const res = await fetch(`https://formsubmit.co/ajax/${notifyEmail()}`, {
      method: "POST",
      // FormSubmit rejects requests without a browser-like Origin/Referer.
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        Origin: "https://arca-the-zone-bio.vercel.app",
        Referer: "https://arca-the-zone-bio.vercel.app/ring",
      },
      body: JSON.stringify({
        _subject: subject,
        _template: "box",
        // FormSubmit renders values as text, so send a plain-text version.
        message: html
          .replace(/<\/(h2|p|li|tr|ul|table)>/g, "\n")
          .replace(/<[^>]+>/g, " ")
          .replace(/&amp;/g, "&")
          .replace(/&lt;/g, "<")
          .replace(/&gt;/g, ">")
          .replace(/[ \t]+/g, " ")
          .trim(),
      }),
    });
    if (!res.ok) return false;
    const j = (await res.json().catch(() => null)) as { success?: string | boolean } | null;
    return j?.success === true || j?.success === "true";
  } catch {
    return false;
  }
}

async function sendSlack(text: string): Promise<boolean> {
  const url = slackWebhookUrl();
  if (!url) return false;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function mapsLink(loc?: RingLocation): string | undefined {
  if (!loc || loc.lat === undefined || loc.lng === undefined) return undefined;
  return `https://maps.google.com/?q=${loc.lat},${loc.lng}`;
}

export async function recordConnection(conn: RingConnection): Promise<Delivery> {
  const where = conn.location?.label ?? "위치 미공유";
  const map = mapsLink(conn.location);
  const nth = conn.meetCount > 1 ? ` — ${conn.meetCount}번째 만남 🔁` : "";

  const rows: Array<[string, string | undefined]> = [
    ["이름", conn.name],
    ["소속", conn.affiliation],
    ["전화", conn.phone],
    ["이메일", conn.email],
    ["메모", conn.note],
    ["카테고리", conn.category],
    ["시간", new Date(conn.occurredAt).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })],
    ["장소", map ? `${where} (${map})` : where],
  ];

  const historyHtml =
    conn.history.length > 1
      ? `<p><b>우리의 히스토리</b></p><ul>${conn.history
          .map(
            (h) =>
              `<li>${esc(new Date(h.at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" }))}${
                h.place ? ` · ${esc(h.place)}` : ""
              }</li>`
          )
          .join("")}</ul>`
      : "";

  const html =
    `<h2>🤝 ARCA Ring connect${esc(nth)}</h2>` +
    `<table cellpadding="6">${rows
      .filter(([, v]) => v)
      .map(([k, v]) => `<tr><td><b>${k}</b></td><td>${esc(v!)}</td></tr>`)
      .join("")}</table>` +
    historyHtml;

  const slackText = [
    `🤝 *ARCA Ring connect*${nth}`,
    `*${conn.name}*${conn.affiliation ? ` · ${conn.affiliation}` : ""} (${conn.category})`,
    [conn.phone, conn.email].filter(Boolean).join(" · "),
    conn.note ? `📝 ${conn.note}` : "",
    `📍 ${where}${map ? ` <${map}|지도>` : ""} · ${new Date(conn.occurredAt).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })}`,
  ]
    .filter(Boolean)
    .join("\n");

  const [file, email, slack] = await Promise.all([
    appendJsonl("connections.jsonl", conn),
    sendEmail(`🤝 Ring connect: ${conn.name}${conn.affiliation ? ` (${conn.affiliation})` : ""}${nth}`, html),
    sendSlack(slackText),
  ]);
  return { file, email, slack };
}

export async function recordWaitlist(entry: WaitlistEntry): Promise<Delivery> {
  const html =
    `<h2>📮 ARCA waitlist signup</h2>` +
    `<p><b>${esc(entry.email)}</b>${entry.name ? ` (${esc(entry.name)})` : ""}</p>` +
    `<p>source: ${esc(entry.source)} · ${esc(
      new Date(entry.createdAt).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })
    )}</p>`;

  const [file, email, slack] = await Promise.all([
    appendJsonl("waitlist.jsonl", entry),
    sendEmail(`📮 ARCA waitlist: ${entry.email}`, html),
    sendSlack(`📮 *ARCA waitlist* — ${entry.email}${entry.name ? ` (${entry.name})` : ""} · ${entry.source}`),
  ]);
  return { file, email, slack };
}

export function newRingId(): string {
  return `${Date.now().toString(36)}-${randomUUID().slice(0, 8)}`;
}
