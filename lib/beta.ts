import { createHmac, timingSafeEqual } from "node:crypto";

/// Mac beta distribution without a database: an approval is a signed link.
/// The owner generates one per tester from /arcadash; the download route
/// checks the signature and expiry, then redirects to the build. Rotating
/// ARCA_BETA_SIGNING_SECRET revokes every link at once.

export const TESTFLIGHT_URL = "https://testflight.apple.com/join/U78MNCxj";

export function betaZipUrl(): string {
  return (
    process.env.ARCA_BETA_ZIP_URL?.trim() ||
    "https://github.com/METHEZONE/arca/releases/latest/download/ARCA-Beta-mac-arm64.zip"
  );
}

function secret(): string {
  const s = process.env.ARCA_BETA_SIGNING_SECRET?.trim();
  if (!s) throw new Error("ARCA_BETA_SIGNING_SECRET is not set");
  return s;
}

export function adminTokenOk(candidate: string | null | undefined): boolean {
  const expected = process.env.ARCA_ADMIN_TOKEN?.trim();
  if (!expected || !candidate) return false;
  const a = Buffer.from(candidate);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export type BetaGrant = { email: string; exp: number };

function payload(email: string, exp: number): string {
  return `${email.trim().toLowerCase()}|${exp}`;
}

export function signGrant(email: string, days = 14): { email: string; exp: number; sig: string } {
  const exp = Math.floor(Date.now() / 1000) + days * 86_400;
  const sig = createHmac("sha256", secret()).update(payload(email, exp)).digest("base64url");
  return { email: email.trim().toLowerCase(), exp, sig };
}

export function verifyGrant(email: string, exp: number, sig: string): boolean {
  if (!email || !exp || !sig) return false;
  if (exp < Math.floor(Date.now() / 1000)) return false;
  const expected = createHmac("sha256", secret()).update(payload(email, exp)).digest("base64url");
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function downloadLink(origin: string, grant: { email: string; exp: number; sig: string }): string {
  const q = new URLSearchParams({ e: grant.email, x: String(grant.exp), s: grant.sig });
  return `${origin}/api/arca/beta/download?${q.toString()}`;
}
