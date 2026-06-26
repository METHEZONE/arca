"use client";

import { useState, type JSX } from "react";
import { copyText } from "./format";
import { IconCopy, IconCheck } from "./icons";

export function CopyItem({
  text,
  variant = "draft",
}: {
  text: string;
  variant?: "draft" | "q";
}): JSX.Element {
  const [copied, setCopied] = useState(false);

  async function onCopy() {
    const ok = await copyText(text);
    if (ok) {
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    }
  }

  return (
    <div className={`copy-item ${variant === "q" ? "q" : ""}`}>
      <span className="ci-text">{text}</span>
      <button
        type="button"
        className={`copy-btn ${copied ? "copied" : ""}`}
        onClick={onCopy}
      >
        {copied ? <IconCheck size={13} /> : <IconCopy size={13} />}
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}
