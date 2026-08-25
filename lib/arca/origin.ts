"use client";

/**
 * `/arca/*` pages can be served through thezonebio.com's multi-zone rewrite
 * (see app/arca/page.tsx's own inline copy of this check) — the page loads
 * fine either way, but its own `fetch()` calls need to be pointed at this
 * app's real origin explicitly, since only the page route is proxied, not
 * arbitrary API paths.
 */
const ARCA_ORIGIN = "https://arca-the-zone-bio.vercel.app";

export function arcaBase(): string {
  if (typeof window === "undefined") return "";
  const h = window.location.hostname;
  return h === "localhost" || h.endsWith(".vercel.app") ? "" : ARCA_ORIGIN;
}
