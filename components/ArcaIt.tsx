"use client";

// The "arca it" command bar — total delegation as a first-class surface.
// ⌘K (or the floating pill) opens the palette; a delegation streams its loop
// (recall → reason → draft → file → report) live, then shows the report.
// The filed report memory is handed to the parent so the feed updates.

import { useCallback, useEffect, useRef, useState, type JSX } from "react";
import type { Memory } from "@/lib/types";
import type { DelegationEvent, DelegationReport, DelegationStepKey } from "@/lib/delegate/engine";
import { CopyItem } from "./CopyItem";
import { IconCheck, IconClose, IconSpark } from "./icons";

const QUESTS = [
  "wrap up my latest meeting",
  "draft follow-ups for everyone I met",
  "what's still open on my plate?",
  "what did we decide about pricing?",
];

const STEP_ORDER: DelegationStepKey[] = ["recall", "reason", "draft", "file", "report"];

type StepState = {
  key: DelegationStepKey;
  label: string;
  detail?: string;
  status: "start" | "done";
};

type Phase = "input" | "running" | "done" | "error";

type Props = {
  onFiled: (memory: Memory) => void;
  notify: (msg: string) => void;
};

export function ArcaIt({ onFiled, notify }: Props): JSX.Element {
  const [open, setOpen] = useState(false);
  const [phase, setPhase] = useState<Phase>("input");
  const [command, setCommand] = useState("");
  const [steps, setSteps] = useState<StepState[]>([]);
  const [report, setReport] = useState<DelegationReport | null>(null);
  const [errorMsg, setErrorMsg] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const abortRef = useRef<AbortController | null>(null);
  // Resolved after mount so SSR and first client render agree (hydration-safe).
  const [isMac, setIsMac] = useState(true);
  useEffect(() => {
    setIsMac(/Mac|iPhone|iPad/.test(navigator.userAgent));
  }, []);

  const reset = useCallback(() => {
    setPhase("input");
    setSteps([]);
    setReport(null);
    setErrorMsg("");
    setCommand("");
  }, []);

  const close = useCallback(() => {
    abortRef.current?.abort();
    setOpen(false);
    reset();
  }, [reset]);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((o) => {
          if (o) abortRef.current?.abort();
          return !o;
        });
        reset();
      }
      if (e.key === "Escape") {
        setOpen((o) => {
          if (o) {
            abortRef.current?.abort();
            reset();
          }
          return false;
        });
      }
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [reset]);

  useEffect(() => {
    if (open && phase === "input") inputRef.current?.focus();
  }, [open, phase]);

  const run = useCallback(
    async (cmd: string) => {
      const trimmed = cmd.trim();
      if (!trimmed) return;
      setPhase("running");
      setSteps([]);
      setReport(null);
      setErrorMsg("");

      const controller = new AbortController();
      abortRef.current = controller;

      try {
        const res = await fetch("/api/arca/delegate", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ command: trimmed }),
          signal: controller.signal,
        });
        if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          let sep: number;
          while ((sep = buffer.indexOf("\n\n")) >= 0) {
            const chunk = buffer.slice(0, sep);
            buffer = buffer.slice(sep + 2);
            const line = chunk.split("\n").find((l) => l.startsWith("data: "));
            if (!line) continue;
            const event = JSON.parse(line.slice(6)) as DelegationEvent;

            if (event.type === "step") {
              setSteps((prev) => {
                const next = prev.filter((s) => s.key !== event.key);
                next.push({
                  key: event.key,
                  label: event.label,
                  detail: event.detail,
                  status: event.status,
                });
                next.sort((a, b) => STEP_ORDER.indexOf(a.key) - STEP_ORDER.indexOf(b.key));
                return next;
              });
            } else if (event.type === "report") {
              setReport(event.report);
              setPhase("done");
              if (event.memory) onFiled(event.memory);
            } else if (event.type === "error") {
              setErrorMsg(event.message);
              setPhase("error");
            }
          }
        }
      } catch (err: unknown) {
        if ((err as Error)?.name === "AbortError") return;
        setErrorMsg("ARCA couldn't reach the delegation engine. Try again.");
        setPhase("error");
      }
    },
    [onFiled],
  );

  async function copyRecap() {
    if (!report) return;
    try {
      await navigator.clipboard.writeText(report.recapMarkdown);
      notify("Recap copied as markdown.");
    } catch {
      notify("Copy failed.");
    }
  }

  return (
    <>
      <button
        type="button"
        className="arcait-pill"
        onClick={() => {
          reset();
          setOpen(true);
        }}
        aria-label='Open the "arca it" command bar'
      >
        <IconSpark size={15} />
        <span className="arcait-pill-verb">arca it</span>
        <kbd>{isMac ? "⌘K" : "Ctrl K"}</kbd>
      </button>

      {open ? (
        <div className="arcait-scrim" onClick={close} role="presentation">
          <div
            className="arcait-panel"
            role="dialog"
            aria-modal="true"
            aria-label="arca it command bar"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="arcait-head">
              <span className="arcait-verb">arca it —</span>
              {phase === "input" ? (
                <form
                  className="arcait-form"
                  onSubmit={(e) => {
                    e.preventDefault();
                    void run(command);
                  }}
                >
                  <input
                    ref={inputRef}
                    value={command}
                    onChange={(e) => setCommand(e.target.value)}
                    placeholder="hand me the whole job…"
                    maxLength={400}
                    aria-label="Delegation command"
                  />
                </form>
              ) : (
                <span className="arcait-cmd">{report?.command ?? command}</span>
              )}
              <button type="button" className="icon-btn" aria-label="Close" onClick={close}>
                <IconClose size={16} />
              </button>
            </div>

            {phase === "input" ? (
              <div className="arcait-quests" aria-label="Suggested delegations">
                {QUESTS.map((q) => (
                  <button
                    key={q}
                    type="button"
                    className="arcait-quest"
                    onClick={() => {
                      setCommand(q);
                      void run(q);
                    }}
                  >
                    {q}
                  </button>
                ))}
                <p className="arcait-hint">
                  Delegate the whole job. ARCA recalls, reasons, drafts, files, and reports back.
                </p>
              </div>
            ) : null}

            {phase === "running" || phase === "done" || phase === "error" ? (
              <ol className="arcait-steps">
                {steps.map((s) => (
                  <li key={s.key} className={`arcait-step ${s.status}`}>
                    <span className="arcait-step-mark">
                      {s.status === "done" ? <IconCheck size={13} /> : <span className="mini-spin" />}
                    </span>
                    <span className="arcait-step-label">{s.label}</span>
                    {s.detail ? <span className="arcait-step-detail">{s.detail}</span> : null}
                  </li>
                ))}
              </ol>
            ) : null}

            {phase === "error" ? (
              <div className="arcait-error" role="alert">
                <p>{errorMsg}</p>
                <button type="button" className="btn-ghost" onClick={reset}>
                  Try again
                </button>
              </div>
            ) : null}

            {phase === "done" && report ? (
              <div className="arcait-report">
                <div className="arcait-headline">
                  <span className="arcait-headline-check">
                    <IconCheck size={15} />
                  </span>
                  {report.headline}
                  <span className="arcait-elapsed">{(report.elapsedMs / 1000).toFixed(1)}s</span>
                </div>
                <p className="arcait-summary">{report.summary}</p>

                {report.memoriesUsed.length > 0 ? (
                  <div className="arcait-used">
                    {report.memoriesUsed.map((m) => (
                      <span key={m.id}>{m.title}</span>
                    ))}
                  </div>
                ) : null}

                {report.followups.length > 0 ? (
                  <section className="arcait-section">
                    <div className="label">Follow-up drafts</div>
                    {report.followups.map((f, i) => (
                      <CopyItem key={i} text={f} />
                    ))}
                  </section>
                ) : null}

                {report.openActions.length > 0 ? (
                  <section className="arcait-section">
                    <div className="label">Still open</div>
                    <ul className="arcait-open">
                      {report.openActions.slice(0, 6).map((a, i) => (
                        <li key={i}>
                          <b>{a.title}</b>
                          <span>
                            {a.owner ? `${a.owner} · ` : ""}
                            {a.memoryTitle}
                          </span>
                        </li>
                      ))}
                    </ul>
                  </section>
                ) : null}

                <div className="arcait-actions">
                  <button type="button" className="btn-primary" onClick={copyRecap}>
                    Copy recap
                  </button>
                  <button type="button" className="btn-ghost" onClick={reset}>
                    Delegate again
                  </button>
                  <span className="arcait-filed">
                    {report.filedMemoryId ? "filed to your second brain ✓" : ""}
                  </span>
                </div>
              </div>
            ) : null}
          </div>
        </div>
      ) : null}
    </>
  );
}
