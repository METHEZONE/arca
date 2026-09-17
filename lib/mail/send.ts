/**
 * One outbound-mail door for transactional email (magic links, beta grants).
 *
 * Order of preference:
 *   1. Resend, when RESEND_API_KEY is set (proper transactional sender).
 *   2. The owner's own Gmail through Composio — the same connection
 *      lib/hardware/notify.ts already uses in production
 *      (COMPOSIO_API_KEY + ARCA_HARDWARE_MAIL_USER). Good enough for a beta:
 *      every sign-in link arrives from Min's real address.
 *
 * Returns true only when a provider accepted the message. Callers decide how
 * to degrade (the magic-link route hands the link back in non-production).
 */

const COMPOSIO = "https://backend.composio.dev/api/v3";

export interface OutboundMail {
  to: string;
  subject: string;
  html: string;
  /** Plain-text body for providers that don't render HTML well. Derived from html when omitted. */
  text?: string;
}

export function mailConfigured(): boolean {
  return Boolean(
    process.env.RESEND_API_KEY?.trim() ||
      (process.env.COMPOSIO_API_KEY?.trim() && process.env.ARCA_HARDWARE_MAIL_USER?.trim()),
  );
}

export async function sendMail(mail: OutboundMail): Promise<boolean> {
  if (await sendViaResend(mail)) return true;
  return sendViaComposioGmail(mail);
}

async function sendViaResend(mail: OutboundMail): Promise<boolean> {
  const key = process.env.RESEND_API_KEY?.trim();
  if (!key) return false;
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: process.env.RING_FROM_EMAIL?.trim() || "ARCA <onboarding@resend.dev>",
        to: [mail.to],
        subject: mail.subject,
        html: mail.html,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

type Account = { id: string; status: string; toolkit?: { slug?: string } };

let cachedGmailAccount: { id: string; at: number } | null = null;

async function sendViaComposioGmail(mail: OutboundMail): Promise<boolean> {
  const key = process.env.COMPOSIO_API_KEY?.trim();
  const userId = process.env.ARCA_HARDWARE_MAIL_USER?.trim();
  if (!key || !userId) return false;
  const headers = { "x-api-key": key, "content-type": "application/json" };
  try {
    let accountId = cachedGmailAccount && Date.now() - cachedGmailAccount.at < 10 * 60_000 ? cachedGmailAccount.id : null;
    if (!accountId) {
      const listed = await fetch(`${COMPOSIO}/connected_accounts?user_ids=${encodeURIComponent(userId)}`, { headers });
      const { items = [] } = (await listed.json()) as { items?: Account[] };
      const gmail = items.find((a) => a.toolkit?.slug === "gmail" && a.status === "ACTIVE");
      if (!gmail) return false;
      accountId = gmail.id;
      cachedGmailAccount = { id: accountId, at: Date.now() };
    }
    const res = await fetch(`${COMPOSIO}/tools/execute/GMAIL_SEND_EMAIL`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        user_id: userId,
        connected_account_id: accountId,
        arguments: { recipient_email: mail.to, subject: mail.subject, body: mail.html, is_html: true },
      }),
    });
    const out = (await res.json().catch(() => ({}))) as { successful?: boolean };
    return res.ok && out.successful !== false;
  } catch {
    return false;
  }
}
