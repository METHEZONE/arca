import { createHash } from "node:crypto";
import { verifyGrant } from "@/lib/beta";

/// ARCA Cloud: the Mac app talks to Anthropic and Composio through here when
/// the user has no keys of their own. Authentication is the invite code
/// (`email.exp.sig`), the same signed grant the download link carries.

export function parseInvite(code: string | null | undefined): { email: string; exp: number; sig: string } | null {
  if (!code) return null;
  const parts = code.trim().split(".");
  if (parts.length < 3) return null;
  const sig = parts[parts.length - 1];
  const exp = Number(parts[parts.length - 2]);
  const email = parts.slice(0, -2).join(".").toLowerCase();
  if (!email.includes("@") || !Number.isFinite(exp) || sig.length < 20) return null;
  return { email, exp, sig };
}

export function authorizeInvite(req: Request): { email: string } | null {
  const code = req.headers.get("x-arca-token") ?? req.headers.get("x-api-key");
  const parsed = parseInvite(code);
  if (!parsed) return null;
  try {
    return verifyGrant(parsed.email, parsed.exp, parsed.sig) ? { email: parsed.email } : null;
  } catch {
    return null;
  }
}

/// One connector identity per email, identical to the app's derivation.
export function composioEntity(email: string): string {
  return "arca-b-" + createHash("sha256").update(email.toLowerCase()).digest("hex").slice(0, 10);
}

export function inviteCode(email: string, exp: number, sig: string): string {
  return `${email.toLowerCase()}.${exp}.${sig}`;
}
