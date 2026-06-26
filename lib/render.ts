// Rendering helpers shared by integrations (Obsidian/Slack) and exports.
// Notion builds its own block structure from the Memory directly.

import type { Memory, Priority } from "@/lib/types";

const PRIORITY_MARK: Record<Priority, string> = {
  high: "🔴",
  medium: "🟡",
  low: "⚪",
};

export function formatDuration(sec: number): string {
  if (!sec || sec < 0) return "0:00";
  const m = Math.floor(sec / 60);
  const s = Math.round(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export function slugify(input: string): string {
  const base = input
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  return base || "memory";
}

/** Full Markdown document for an Obsidian note / file export. */
export function memoryToMarkdown(memory: Memory): string {
  const { analysis, transcript } = memory;
  const date = new Date(memory.createdAt);
  const lines: string[] = [];

  // YAML frontmatter — Obsidian-friendly, queryable.
  lines.push("---");
  lines.push(`title: "${analysis.title.replace(/"/g, "'")}"`);
  lines.push(`created: ${memory.createdAt}`);
  lines.push(`source: "${memory.sourceFileName}"`);
  lines.push(`duration: ${formatDuration(memory.durationSec)}`);
  lines.push(`speakers: ${memory.speakerCount}`);
  lines.push(`provider: ${analysis.provider}`);
  if (memory.tags.length) lines.push(`tags: [${memory.tags.join(", ")}]`);
  if (analysis.topics.length)
    lines.push(`topics: [${analysis.topics.map((t) => `"${t}"`).join(", ")}]`);
  lines.push("---");
  lines.push("");

  lines.push(`# ${analysis.title}`);
  lines.push("");
  lines.push(
    `> 🧠 ARCA memory · ${date.toLocaleString()} · ${formatDuration(memory.durationSec)} · ${memory.speakerCount} speakers`,
  );
  lines.push("");

  lines.push("## Summary");
  lines.push(analysis.summary);
  lines.push("");

  if (analysis.highlights.length) {
    lines.push("## Highlights");
    for (const h of analysis.highlights) lines.push(`- ${h}`);
    lines.push("");
  }

  if (analysis.decisions.length) {
    lines.push("## Decisions");
    for (const d of analysis.decisions) {
      lines.push(`- ${d.text}`);
      if (d.sourceQuote) lines.push(`  > ${d.sourceQuote}`);
    }
    lines.push("");
  }

  if (analysis.actionItems.length) {
    lines.push("## Action plan");
    for (const a of analysis.actionItems) {
      const box = a.status === "done" ? "x" : " ";
      const meta = [
        a.owner ? `@${a.owner}` : null,
        a.due ? `due ${a.due}` : null,
        `${PRIORITY_MARK[a.priority]} ${a.priority}`,
      ]
        .filter(Boolean)
        .join(" · ");
      lines.push(`- [${box}] ${a.title}${meta ? ` — ${meta}` : ""}`);
      if (a.sourceQuote) lines.push(`  > ${a.sourceQuote}`);
    }
    lines.push("");
  }

  if (analysis.openQuestions.length) {
    lines.push("## Open questions");
    for (const q of analysis.openQuestions) lines.push(`- ${q}`);
    lines.push("");
  }

  if (analysis.followups.length) {
    lines.push("## Follow-up drafts");
    for (const f of analysis.followups) {
      lines.push("```");
      lines.push(f);
      lines.push("```");
    }
    lines.push("");
  }

  lines.push("## Transcript + speakers");
  for (const seg of transcript.segments) {
    lines.push(
      `**${seg.speakerLabel}** \`${formatDuration(seg.startMs / 1000)}\`: ${seg.text}`,
    );
  }
  lines.push("");

  return lines.join("\n");
}

/** Compact plaintext summary for Slack (mrkdwn) and previews. */
export function memoryToSlackText(memory: Memory): string {
  const { analysis } = memory;
  const parts: string[] = [];
  parts.push(`*🧠 ${analysis.title}*`);
  parts.push(
    `_${memory.sourceFileName} · ${formatDuration(memory.durationSec)} · ${memory.speakerCount} speakers · via ${analysis.provider}_`,
  );
  parts.push("");
  parts.push(analysis.summary);
  if (analysis.decisions.length) {
    parts.push("");
    parts.push("*Decisions*");
    for (const d of analysis.decisions) parts.push(`• ${d.text}`);
  }
  if (analysis.actionItems.length) {
    parts.push("");
    parts.push("*Action plan*");
    for (const a of analysis.actionItems) {
      const meta = [a.owner ? `@${a.owner}` : null, a.due ?? null]
        .filter(Boolean)
        .join(" · ");
      parts.push(
        `${a.status === "done" ? "✅" : PRIORITY_MARK[a.priority]} ${a.title}${meta ? ` (${meta})` : ""}`,
      );
    }
  }
  return parts.join("\n");
}

/** Slack Block Kit payload. */
export function memoryToSlackBlocks(memory: Memory): unknown[] {
  const { analysis } = memory;
  const blocks: unknown[] = [
    {
      type: "header",
      text: { type: "plain_text", text: `🧠 ${analysis.title}`.slice(0, 150) },
    },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `${memory.sourceFileName} · ${formatDuration(memory.durationSec)} · ${memory.speakerCount} speakers · via ${analysis.provider}`,
        },
      ],
    },
    { type: "section", text: { type: "mrkdwn", text: analysis.summary.slice(0, 2900) } },
  ];

  if (analysis.actionItems.length) {
    const text = analysis.actionItems
      .map((a) => {
        const meta = [a.owner ? `@${a.owner}` : null, a.due ?? null]
          .filter(Boolean)
          .join(" · ");
        return `${a.status === "done" ? "✅" : PRIORITY_MARK[a.priority]} ${a.title}${meta ? ` (${meta})` : ""}`;
      })
      .join("\n")
      .slice(0, 2900);
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: `*Action plan*\n${text}` },
    });
  }

  return blocks;
}
