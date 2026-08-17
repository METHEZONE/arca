import { appendFile, mkdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import { NextRequest, NextResponse } from "next/server";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { dataDir, slackWebhookUrl } from "@/lib/config";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** A MetricKit call-stack tree is large but not unbounded. */
const MAX_BYTES = 2 * 1024 * 1024;
/** One payload can carry several diagnostics; more than this is a loop. */
const MAX_REPORTS = 20;

/**
 * Crash + hang intake for the native app.
 *
 * The app has no crash SDK — it uses Apple's MetricKit, which hands over
 * diagnostics on a *later* launch rather than at crash time. So a report
 * arriving here is always about something that already happened, often
 * yesterday. That latency is the whole reason this endpoint is dumb: it takes
 * whatever the OS produced and makes it durable somewhere Min can read it.
 *
 * Unauthenticated on purpose, unlike the chat and transcribe proxies. Those
 * spend money and must know whose budget to spend; this one spends nothing, and
 * the report you most want is the one from an install so broken it never got a
 * device token. The token is still honoured when present so a crash can be tied
 * to a device's usage; the abuse guard is the body-size cap.
 *
 * Persistence mirrors ARCA Ring: a JSONL file under the data dir, which is
 * `/tmp` and therefore ephemeral on Vercel — so every report is also emitted as
 * a single `arca.crash` log line (grep it out of `vercel logs`) and pushed to
 * Slack when a webhook is configured. On a self-hosted deploy the file is the
 * durable copy.
 */
export async function POST(request: NextRequest) {
  const raw = await request.text();
  if (raw.length > MAX_BYTES) {
    return NextResponse.json({ error: "Crash report too large." }, { status: 413 });
  }

  let body: { installId?: unknown; reports?: unknown };
  try {
    body = JSON.parse(raw) as { installId?: unknown; reports?: unknown };
  } catch {
    return NextResponse.json({ error: "Body must be JSON." }, { status: 400 });
  }

  const reports = Array.isArray(body.reports) ? body.reports.slice(0, MAX_REPORTS) : null;
  if (!reports || reports.length === 0) {
    return NextResponse.json(
      { error: "reports must be a non-empty array." },
      { status: 400 },
    );
  }

  const installId = typeof body.installId === "string" ? body.installId : undefined;
  const received = {
    at: new Date().toISOString(),
    installId,
    // Present only for installs that already minted a device token.
    deviceId: deviceIdFromRequest(request) ?? undefined,
    reports,
  };

  for (const report of reports) {
    console.log(`arca.crash ${JSON.stringify(summarize(report, installId))}`);
  }

  const [file, slack] = await Promise.all([
    appendJsonl(received),
    notifySlack(reports, installId),
  ]);

  return NextResponse.json({ accepted: reports.length, stored: { file, slack } });
}

/** The one-line version: enough to triage from a log or a phone notification. */
function summarize(report: unknown, installId?: string): Record<string, unknown> {
  const r = (typeof report === "object" && report !== null ? report : {}) as Record<
    string,
    unknown
  >;
  return {
    kind: r.kind,
    installId,
    appVersion: r.appVersion,
    buildVersion: r.buildVersion,
    osVersion: r.osVersion,
    deviceModel: r.deviceModel,
    platform: r.platform,
    exceptionType: r.exceptionType,
    signal: r.signal,
    terminationReason: r.terminationReason,
    hangSeconds: r.hangSeconds,
  };
}

function crashDir(): string {
  const configured = dataDir();
  const base =
    process.env.VERCEL && !isAbsolute(configured)
      ? join("/tmp", configured)
      : isAbsolute(configured)
        ? configured
        : join(process.cwd(), configured);
  return join(base, "crash");
}

async function appendJsonl(record: unknown): Promise<boolean> {
  try {
    await mkdir(crashDir(), { recursive: true });
    await appendFile(join(crashDir(), "reports.jsonl"), JSON.stringify(record) + "\n", "utf-8");
    return true;
  } catch {
    return false;
  }
}

async function notifySlack(reports: unknown[], installId?: string): Promise<boolean> {
  const url = slackWebhookUrl();
  if (!url) return false;
  const lines = reports.slice(0, 3).map((report) => {
    const s = summarize(report, installId);
    const what =
      s.kind === "hang"
        ? `hang ${Number(s.hangSeconds ?? 0).toFixed(1)}s`
        : `crash${s.signal ? ` · signal ${s.signal}` : ""}${
            s.terminationReason ? ` · ${s.terminationReason}` : ""
          }`;
    return `• ${what} — ${s.platform ?? "?"} ${s.osVersion ?? "?"} · ${s.deviceModel ?? "?"} · app ${
      s.appVersion ?? "?"
    } (${s.buildVersion ?? "?"})`;
  });
  const more = reports.length > lines.length ? `\n… +${reports.length - lines.length} more` : "";
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text: [`💥 *ARCA crash report* (install ${installId ?? "unknown"})`, ...lines].join("\n") + more,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}
