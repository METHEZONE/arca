"use client";

import { arcaBase } from "@/lib/arca/origin";

/**
 * Gets or mints a browser device token for anonymous ARCA Cloud calls (the
 * public "arca it" widget on the marketing site) — the same device-token
 * model `lib/arca/device.ts` issues to the app, cached in localStorage so a
 * visitor keeps one identity across the session instead of minting a new
 * device — and burning a fresh free-tier quota — on every command.
 */
const STORAGE_KEY = "arca_device_token";

export async function getDeviceToken(): Promise<string | null> {
  let cached: string | null = null;
  try {
    cached = localStorage.getItem(STORAGE_KEY);
  } catch {
    return null; // localStorage unavailable (private mode, disabled storage)
  }
  if (cached) return cached;

  try {
    const res = await fetch(`${arcaBase()}/api/arca/device`, { method: "POST" });
    if (!res.ok) return null;
    const { token } = (await res.json()) as { token?: string };
    if (!token) return null;
    localStorage.setItem(STORAGE_KEY, token);
    return token;
  } catch {
    return null;
  }
}
