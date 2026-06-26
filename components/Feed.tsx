import type { JSX } from "react";
import type { MemorySummary, IntegrationTarget } from "@/lib/types";
import { formatDuration, formatRelative } from "./format";
import { IconClock, IconUsers } from "./icons";

const TARGETS: { key: IntegrationTarget; short: string }[] = [
  { key: "obsidian", short: "Ob" },
  { key: "notion", short: "No" },
  { key: "slack", short: "Sl" },
];

type Props = {
  memories: MemorySummary[];
  loading: boolean;
  onOpen: (id: string) => void;
};

export function Feed({ memories, loading, onOpen }: Props): JSX.Element {
  return (
    <section>
      <div className="feed-head">
        <h2>Second Brain</h2>
        <span className="count">
          {loading ? "Loading..." : `${memories.length} memories`}
        </span>
      </div>

      {loading ? (
        <div className="feed-skeleton">
          {Array.from({ length: 4 }).map((_, i) => (
            <div key={i} className="skel" />
          ))}
        </div>
      ) : memories.length === 0 ? (
        <div className="empty-feed">
          <div className="glyph">A</div>
          <h3>Add the first memory</h3>
          <p>
            Record or upload a meeting, interview, thought, or hardware capture. ARCA will keep
            the speaker transcript, summary, decisions, and action plan here.
          </p>
        </div>
      ) : (
        <div className="feed">
          {memories.map((m, idx) => (
            <MemoryCard key={m.id} m={m} index={idx} onOpen={onOpen} />
          ))}
        </div>
      )}
    </section>
  );
}

function MemoryCard({
  m,
  index,
  onOpen,
}: {
  m: MemorySummary;
  index: number;
  onOpen: (id: string) => void;
}): JSX.Element {
  const synced = new Set(
    m.integrations.filter((i) => i.status === "success").map((i) => i.target),
  );
  return (
    <button
      type="button"
      className="mem-card"
      style={{ animationDelay: `${Math.min(index, 8) * 0.04}s` }}
      onClick={() => onOpen(m.id)}
    >
      <div className="top">
        <span className="title">{m.title}</span>
        <span className="when">{formatRelative(m.createdAt)}</span>
      </div>

      {m.summary ? <p className="summary">{m.summary}</p> : null}

      {m.topics.length > 0 ? (
        <div className="chips">
          {m.topics.slice(0, 4).map((t) => (
            <span key={t} className="chip">
              {t}
            </span>
          ))}
        </div>
      ) : null}

      <div className="meta-row">
        <span className="m">
          <IconClock size={13} />
          {formatDuration(m.durationSec)}
        </span>
        <span className="m">
          <IconUsers size={13} />
          {m.speakerCount} speakers
        </span>
        {m.actionItemCount > 0 ? (
          <span className="m">
            <span className={m.openActionItemCount > 0 ? "ai-open" : ""}>
              {m.openActionItemCount > 0
                ? `To do ${m.openActionItemCount}/${m.actionItemCount}`
                : `Done (${m.actionItemCount})`}
            </span>
          </span>
        ) : null}
        <span className="sync-badges" style={{ marginLeft: "auto" }}>
          {TARGETS.map((t) => (
            <span
              key={t.key}
              className={`sb ${synced.has(t.key) ? "on" : ""}`}
              title={`${t.key}${synced.has(t.key) ? " · synced" : " · not synced"}`}
            >
              {t.short}
            </span>
          ))}
        </span>
      </div>
    </button>
  );
}
