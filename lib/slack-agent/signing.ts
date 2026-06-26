import { createHmac, timingSafeEqual } from "crypto";

const FIVE_MINUTES_SECONDS = 60 * 5;

export function verifySlackSignature(params: {
  body: string;
  signingSecret: string;
  timestamp: string | null;
  signature: string | null;
  nowSeconds?: number;
}): boolean {
  const { body, signingSecret, timestamp, signature } = params;
  if (!timestamp || !signature) return false;

  const requestTs = Number(timestamp);
  if (!Number.isFinite(requestTs)) return false;

  const now = params.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - requestTs) > FIVE_MINUTES_SECONDS) return false;

  const base = `v0:${timestamp}:${body}`;
  const digest = createHmac("sha256", signingSecret).update(base).digest("hex");
  const expected = `v0=${digest}`;

  const expectedBuffer = Buffer.from(expected);
  const actualBuffer = Buffer.from(signature);
  if (expectedBuffer.length !== actualBuffer.length) return false;

  return timingSafeEqual(expectedBuffer, actualBuffer);
}
