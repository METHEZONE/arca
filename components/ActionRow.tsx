"use client";

import { useState, type JSX } from "react";
import type { ActionItem, ActionStatus } from "@/lib/types";
import { IconCheck } from "./icons";

const PRIO_LABEL: Record<string, string> = {
  high: "High",
  medium: "Medium",
  low: "Low",
};

const NEXT: Record<ActionStatus, ActionStatus> = {
  todo: "doing",
  doing: "done",
  done: "todo",
};

export function ActionRow({
  item,
  onToggle,
}: {
  item: ActionItem;
  onToggle: (id: string, status: ActionStatus) => void;
}): JSX.Element {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className={`action ${item.status === "done" ? "done" : ""}`}>
      <div className="action-row">
        <button
          type="button"
          className={`checkbox ${item.status}`}
          aria-label={`Change status, currently ${item.status}`}
          title={`Click: ${item.status} -> ${NEXT[item.status]}`}
          onClick={() => onToggle(item.id, NEXT[item.status])}
        >
          {item.status === "done" ? (
            <IconCheck size={14} />
          ) : item.status === "doing" ? (
            <span style={{ fontSize: 13, lineHeight: 1 }}>•</span>
          ) : null}
        </button>

        <div className="body">
          <div className="a-title">{item.title}</div>
          <div className="a-meta">
            <span className={`prio ${item.priority}`}>{PRIO_LABEL[item.priority]}</span>
            {item.owner ? <span>@{item.owner}</span> : null}
            {item.due ? <span>~{item.due}</span> : null}
            {item.status === "doing" ? <span style={{ color: "var(--copper)" }}>In progress</span> : null}
          </div>
        </div>

        {item.sourceQuote ? (
          <button
            type="button"
            className="a-expand"
            onClick={() => setExpanded((v) => !v)}
          >
            {expanded ? "Hide quote" : "Quote"}
          </button>
        ) : null}
      </div>

      {expanded && item.sourceQuote ? (
        <div className="a-quote">“{item.sourceQuote}”</div>
      ) : null}
    </div>
  );
}
