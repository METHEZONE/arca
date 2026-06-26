"use client";

import { useEffect, useState, type JSX } from "react";
import type {
  Memory,
  ActionStatus,
  IntegrationTarget,
  IntegrationResult,
} from "@/lib/types";
import { formatDate, formatDuration } from "./format";
import { Transcript } from "./Transcript";
import { ActionRow } from "./ActionRow";
import { CopyItem } from "./CopyItem";
import { IconClose, IconTrash, IconClock, IconUsers, IconCheck } from "./icons";

const SYNC_TARGETS: { key: IntegrationTarget; label: string }[] = [
  { key: "obsidian", label: "Obsidian" },
  { key: "notion", label: "Notion" },
  { key: "slack", label: "Slack" },
];

type SyncState = "idle" | "syncing";

type Props = {
  memory: Memory | null;
  loading: boolean;
  onClose: () => void;
  onUpdated: (memory: Memory) => void;
  onDeleted: (id: string) => void;
  notify: (msg: string) => void;
};

export function MemoryDrawer({
  memory,
  loading,
  onClose,
  onUpdated,
  onDeleted,
  notify,
}: Props): JSX.Element {
  const [syncing, setSyncing] = useState<Record<string, SyncState>>({});
  const [confirming, setConfirming] = useState(false);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        if (confirming) setConfirming(false);
        else onClose();
      }
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose, confirming]);

  async function toggleAction(actionItemId: string, status: ActionStatus) {
    if (!memory) return;
    // Optimistic update.
    const optimistic: Memory = {
      ...memory,
      analysis: {
        ...memory.analysis,
        actionItems: memory.analysis.actionItems.map((a) =>
          a.id === actionItemId ? { ...a, status } : a,
        ),
      },
    };
    onUpdated(optimistic);
    try {
      const res = await fetch(`/api/memories/${memory.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ actionItemId, status }),
      });
      if (!res.ok) throw new Error();
      const updated = (await res.json()) as Memory;
      onUpdated(updated);
    } catch {
      onUpdated(memory); // revert
      notify("Action status update failed.");
    }
  }

  async function sync(target: IntegrationTarget) {
    if (!memory) return;
    setSyncing((s) => ({ ...s, [target]: "syncing" }));
    try {
      const res = await fetch("/api/integrations", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ memoryId: memory.id, targets: [target] }),
      });
      if (!res.ok) throw new Error();
      const data = (await res.json()) as {
        results: IntegrationResult[];
        memory: Memory;
      };
      onUpdated(data.memory);
      const result = data.results.find((r) => r.target === target);
      notify(
        result?.status === "success"
          ? `${target} connector synced.`
          : `${target} connector: ${result?.detail ?? "skipped"}`,
      );
    } catch {
      notify(`${target} connector sync failed.`);
    } finally {
      setSyncing((s) => ({ ...s, [target]: "idle" }));
    }
  }

  async function remove() {
    if (!memory) return;
    const id = memory.id;
    try {
      const res = await fetch(`/api/memories/${id}`, { method: "DELETE" });
      if (!res.ok) throw new Error();
      onDeleted(id);
      notify("Memory deleted.");
    } catch {
      notify("Delete failed.");
    } finally {
      setConfirming(false);
    }
  }

  function syncStatus(target: IntegrationTarget): IntegrationResult | undefined {
    return memory?.integrations
      .filter((i) => i.target === target)
      .sort((a, b) => b.at.localeCompare(a.at))[0];
  }

  return (
    <>
      <div className="scrim" onClick={onClose} aria-hidden="true" />
      <div className="drawer" role="dialog" aria-modal="true" aria-label="Memory detail">
        <div className="drawer-bar">
          <button type="button" className="icon-btn" aria-label="Close" onClick={onClose}>
            <IconClose size={18} />
          </button>
          {memory ? (
            <button
              type="button"
              className="icon-btn danger"
              aria-label="Delete memory"
              onClick={() => setConfirming(true)}
            >
              <IconTrash size={17} />
            </button>
          ) : (
            <span />
          )}
        </div>

        {loading || !memory ? (
          <div className="drawer-loading">
            <span className="big-spin" />
            <span>Loading memory...</span>
          </div>
        ) : (
          <div className="drawer-body">
            <h1 className="detail-title">{memory.analysis.title}</h1>
            <div className="detail-meta">
              <span className="m">{formatDate(memory.createdAt)}</span>
              <span className="m">
                <IconClock size={13} /> {formatDuration(memory.durationSec)}
              </span>
              <span className="m">
                <IconUsers size={13} /> {memory.speakerCount} speakers
              </span>
              <span className="m">via {memory.analysis.provider}</span>
            </div>

            <div className="sync-row">
              {SYNC_TARGETS.map((t) => {
                const st = syncStatus(t.key);
                const isSyncing = syncing[t.key] === "syncing";
                const done = st?.status === "success";
                const errored = st?.status === "error";
                return (
                  <button
                    key={t.key}
                    type="button"
                    className={`sync-btn ${done ? "synced" : ""} ${errored ? "error" : ""}`}
                    disabled={isSyncing}
                    onClick={() => sync(t.key)}
                    title={st?.detail ?? ""}
                  >
                    {isSyncing ? (
                      <span className="mini-spin" />
                    ) : done ? (
                      <span className="check">
                        <IconCheck size={14} />
                      </span>
                    ) : null}
                    {t.label}
                    {done ? " · synced" : errored ? " · error" : ""}
                  </button>
                );
              })}
            </div>

            {memory.analysis.warning ? (
              <div className="warn-banner" style={{ marginTop: 20 }}>
                <span>⚠</span>
                <span>{memory.analysis.warning}</span>
              </div>
            ) : null}

            <section className="section">
              <div className="label">Summary</div>
              <p className="lead-para">{memory.analysis.summary}</p>
              {memory.analysis.highlights.length > 0 ? (
                <ul className="highlights">
                  {memory.analysis.highlights.map((h, i) => (
                    <li key={i}>{h}</li>
                  ))}
                </ul>
              ) : null}
            </section>

            {memory.analysis.decisions.length > 0 ? (
              <section className="section">
                <div className="label">Decisions</div>
                {memory.analysis.decisions.map((d, i) => (
                  <div className="decision" key={i}>
                    <div className="text">{d.text}</div>
                    {d.sourceQuote ? <blockquote>“{d.sourceQuote}”</blockquote> : null}
                  </div>
                ))}
              </section>
            ) : null}

            {memory.analysis.actionItems.length > 0 ? (
              <section className="section">
                <div className="label">Action plan</div>
                {memory.analysis.actionItems.map((item) => (
                  <ActionRow key={item.id} item={item} onToggle={toggleAction} />
                ))}
              </section>
            ) : null}

            {memory.analysis.openQuestions.length > 0 ? (
              <section className="section">
                <div className="label">Open questions</div>
                {memory.analysis.openQuestions.map((q, i) => (
                  <CopyItem key={i} text={q} variant="q" />
                ))}
              </section>
            ) : null}

            {memory.analysis.followups.length > 0 ? (
              <section className="section">
                <div className="label">Follow-up drafts</div>
                {memory.analysis.followups.map((f, i) => (
                  <CopyItem key={i} text={f} />
                ))}
              </section>
            ) : null}

            <section className="section">
              <div className="label">Transcript + speakers</div>
              <Transcript transcript={memory.transcript} />
            </section>
          </div>
        )}
      </div>

      {confirming ? (
        <div className="confirm" onClick={() => setConfirming(false)}>
          <div className="confirm-card" onClick={(e) => e.stopPropagation()}>
            <h3>Delete this memory?</h3>
            <p>
              The transcript, notes, and action plan will be permanently removed. This cannot be
              undone.
            </p>
            <div className="confirm-actions">
              <button type="button" className="btn-ghost" onClick={() => setConfirming(false)}>
                Cancel
              </button>
              <button type="button" className="btn-danger" onClick={remove}>
                Delete
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
