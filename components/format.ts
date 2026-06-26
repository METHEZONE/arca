// Self-contained UI formatting helpers (no lib imports by design).

export function formatDuration(totalSec: number): string {
  const sec = Math.max(0, Math.round(totalSec));
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export function formatClock(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
}

export function formatRelative(iso: string): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "";
  const diff = Date.now() - then;
  const min = Math.round(diff / 60000);
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.round(hr / 24);
  if (day < 7) return `${day}d ago`;
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });
}

export function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

// Deterministic, harmonious speaker palette. Indexed by speaker order.
const SPEAKER_PALETTE = [
  { ink: "#1F6F5C", soft: "rgba(31, 111, 92, 0.10)", line: "rgba(31, 111, 92, 0.28)" },
  { ink: "#C2683A", soft: "rgba(194, 104, 58, 0.10)", line: "rgba(194, 104, 58, 0.28)" },
  { ink: "#3A6EA5", soft: "rgba(58, 110, 165, 0.10)", line: "rgba(58, 110, 165, 0.28)" },
  { ink: "#8A5BA8", soft: "rgba(138, 91, 168, 0.10)", line: "rgba(138, 91, 168, 0.28)" },
  { ink: "#B0883C", soft: "rgba(176, 136, 60, 0.12)", line: "rgba(176, 136, 60, 0.30)" },
  { ink: "#52796F", soft: "rgba(82, 121, 111, 0.10)", line: "rgba(82, 121, 111, 0.28)" },
  { ink: "#A14B5B", soft: "rgba(161, 75, 91, 0.10)", line: "rgba(161, 75, 91, 0.28)" },
];

export type SpeakerColor = { ink: string; soft: string; line: string };

export function speakerColor(index: number): SpeakerColor {
  return SPEAKER_PALETTE[((index % SPEAKER_PALETTE.length) + SPEAKER_PALETTE.length) % SPEAKER_PALETTE.length];
}

export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}
