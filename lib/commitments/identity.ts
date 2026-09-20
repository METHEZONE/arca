/**
 * "Don't introduce yourself. Let ARCA try."
 *
 * Builds identity CANDIDATES from public signals only, keyed off the
 * signed-in email. Nothing here is saved — candidates are shown with their
 * sources and confidence, and only what the user confirms is written to
 * `profiles` (see profile.ts). No scraping of private or paywalled data.
 */

import { createHash } from "node:crypto";

import type { ProfileSource } from "@/lib/db/schema";

/** Short-lived httpOnly hint (Google name/picture from the id_token) set by
 *  the OAuth callback for the candidate step. Never persisted server-side. */
export const GOOGLE_HINT_COOKIE = "arca_ghint";

export function readGoogleHint(cookie: string | undefined): { name: string | null; picture: string | null } {
  if (!cookie) return { name: null, picture: null };
  try {
    const j = JSON.parse(Buffer.from(cookie, "base64url").toString("utf8")) as { n?: string | null; p?: string | null };
    return { name: j.n ?? null, picture: j.p ?? null };
  } catch {
    return { name: null, picture: null };
  }
}

export type IdentityCandidate = {
  displayName: string | null;
  headline: string | null;
  company: string | null;
  companyUrl: string | null;
  avatarUrl: string | null;
  /** 0–1. ≥ 0.7 → "혹시 이분이 맞나요?", lower → ask more openly. */
  confidence: number;
  sources: ProfileSource[];
};

const FREE_MAIL = new Set([
  "gmail.com", "googlemail.com", "naver.com", "daum.net", "hanmail.net", "kakao.com", "outlook.com",
  "hotmail.com", "live.com", "yahoo.com", "icloud.com", "me.com", "proton.me", "protonmail.com", "nate.com",
]);

function withTimeout(ms: number): AbortSignal {
  const c = new AbortController();
  setTimeout(() => c.abort(), ms);
  return c.signal;
}

type Gravatar = {
  entry?: Array<{
    displayName?: string;
    aboutMe?: string;
    thumbnailUrl?: string;
    currentLocation?: string;
    profileUrl?: string;
    accounts?: Array<{ shortname?: string; url?: string }>;
    urls?: Array<{ title?: string; value?: string }>;
    name?: { formatted?: string };
    job_title?: string;
    company?: string;
  }>;
};

async function gravatar(email: string): Promise<Partial<IdentityCandidate> & { hit: boolean }> {
  const hash = createHash("sha256").update(email.trim().toLowerCase()).digest("hex");
  try {
    const res = await fetch(`https://gravatar.com/${hash}.json`, {
      headers: { "User-Agent": "ARCA/1.0 (+https://thezonebio.com/arca)" },
      signal: withTimeout(4000),
    });
    if (!res.ok) return { hit: false };
    const data = (await res.json()) as Gravatar;
    const e = data.entry?.[0];
    if (!e) return { hit: false };
    const url = e.profileUrl ?? `https://gravatar.com/${hash}`;
    return {
      hit: true,
      displayName: e.displayName ?? e.name?.formatted ?? null,
      headline: e.job_title ?? e.aboutMe?.slice(0, 120) ?? null,
      company: e.company ?? null,
      avatarUrl: e.thumbnailUrl ? `${e.thumbnailUrl}?s=200` : null,
      sources: [{ kind: "gravatar", label: "Gravatar 공개 프로필", url, confidence: 0.75 }],
    };
  } catch {
    return { hit: false };
  }
}

function meta(html: string, name: string): string | null {
  const re = new RegExp(`<meta[^>]+(?:property|name)=["']${name}["'][^>]*content=["']([^"']+)["']`, "i");
  const re2 = new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']${name}["']`, "i");
  const m = html.match(re) ?? html.match(re2);
  return m ? decode(m[1]) : null;
}
function decode(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .trim();
}

async function domainSignal(email: string): Promise<Partial<IdentityCandidate> & { hit: boolean }> {
  const domain = email.split("@")[1]?.toLowerCase();
  if (!domain || FREE_MAIL.has(domain)) return { hit: false };
  const url = `https://${domain}/`;
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; ARCA/1.0; +https://thezonebio.com/arca)", Accept: "text/html" },
      signal: withTimeout(5000),
      redirect: "follow",
    });
    if (!res.ok) return { hit: false };
    const html = (await res.text()).slice(0, 200000);
    const title = html.match(/<title[^>]*>([^<]{1,160})<\/title>/i)?.[1];
    const siteName = meta(html, "og:site_name");
    const desc = meta(html, "description") ?? meta(html, "og:description");
    const company = siteName ?? (title ? decode(title).split(/[|·\-–—:]/)[0].trim() : null);
    if (!company) return { hit: false };
    return {
      hit: true,
      company,
      companyUrl: url,
      headline: desc ? desc.slice(0, 140) : null,
      sources: [{ kind: "domain", label: `이메일 도메인 ${domain} 공개 홈페이지`, url, confidence: 0.6 }],
    };
  } catch {
    return { hit: false };
  }
}

export async function buildCandidates(input: {
  email: string;
  googleName?: string | null;
  googlePicture?: string | null;
}): Promise<{ candidates: IdentityCandidate[]; checked: string[] }> {
  const [g, d] = await Promise.all([gravatar(input.email), domainSignal(input.email)]);
  const sources: ProfileSource[] = [];
  let confidence = 0.2;
  const localPart = input.email.split("@")[0];

  let displayName: string | null = null;
  if (input.googleName) {
    displayName = input.googleName;
    sources.push({ kind: "google", label: "Google 계정 이름 (로그인 시 제공)", confidence: 0.9 });
    confidence = Math.max(confidence, 0.7);
  }
  if (g.hit) {
    displayName = displayName ?? g.displayName ?? null;
    sources.push(...(g.sources ?? []));
    confidence = Math.max(confidence, 0.75);
  }
  if (d.hit) {
    sources.push(...(d.sources ?? []));
    confidence = Math.max(confidence, displayName ? 0.8 : 0.55);
  }

  const candidate: IdentityCandidate = {
    displayName,
    headline: g.headline ?? null,
    company: g.company ?? d.company ?? null,
    companyUrl: d.companyUrl ?? null,
    avatarUrl: input.googlePicture ?? g.avatarUrl ?? null,
    confidence: Math.min(0.92, confidence),
    sources,
  };
  // If nothing public was found, still offer an honest, low-confidence guess
  // built only from the address itself (clearly labelled as such).
  if (sources.length === 0) {
    candidate.displayName = null;
    candidate.confidence = 0.15;
    candidate.sources.push({ kind: "user", label: `이메일 주소만 알고 있어요 (${localPart}@…)`, confidence: 0.15 });
  }
  const checked = ["Google 계정 (로그인 정보)", "Gravatar 공개 프로필", "이메일 도메인 공개 홈페이지"];
  return { candidates: [candidate], checked };
}
