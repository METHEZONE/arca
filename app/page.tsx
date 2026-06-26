"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { Capabilities, Memory, MemorySummary } from "@/lib/types";
import { TopBar } from "@/components/TopBar";
import { Capture } from "@/components/Capture";
import { Feed } from "@/components/Feed";
import { MemoryDrawer } from "@/components/MemoryDrawer";
import { HardwareBridge } from "@/components/HardwareBridge";

function summarize(m: Memory): MemorySummary {
  return {
    id: m.id,
    createdAt: m.createdAt,
    title: m.analysis.title,
    summary: m.analysis.summary,
    sourceFileName: m.sourceFileName,
    durationSec: m.durationSec,
    speakerCount: m.speakerCount,
    topics: m.analysis.topics,
    actionItemCount: m.analysis.actionItems.length,
    openActionItemCount: m.analysis.actionItems.filter((a) => a.status !== "done").length,
    tags: m.tags,
    integrations: m.integrations,
    isDemo: m.isDemo,
  };
}

export default function Home() {
  const [caps, setCaps] = useState<Capabilities | null>(null);
  const [memories, setMemories] = useState<MemorySummary[]>([]);
  const [feedLoading, setFeedLoading] = useState(true);

  const [openId, setOpenId] = useState<string | null>(null);
  const [detail, setDetail] = useState<Memory | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);

  const [toast, setToast] = useState("");
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const notify = useCallback((msg: string) => {
    setToast(msg);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(""), 2600);
  }, []);

  useEffect(() => {
    fetch("/api/capabilities")
      .then((r) => (r.ok ? r.json() : null))
      .then((data: Capabilities | null) => {
        if (data) setCaps(data);
      })
      .catch(() => undefined);

    fetch("/api/memories")
      .then((r) => (r.ok ? r.json() : []))
      .then((data: MemorySummary[]) => setMemories(Array.isArray(data) ? data : []))
      .catch(() => setMemories([]))
      .finally(() => setFeedLoading(false));
  }, []);

  const openMemory = useCallback(async (id: string) => {
    setOpenId(id);
    setDetail(null);
    setDetailLoading(true);
    try {
      const res = await fetch(`/api/memories/${id}`);
      if (res.ok) setDetail((await res.json()) as Memory);
    } catch {
      // The drawer remains closeable if the detail fetch fails.
    } finally {
      setDetailLoading(false);
    }
  }, []);

  const onProcessed = useCallback(
    (memory: Memory) => {
      setMemories((prev) => [summarize(memory), ...prev.filter((m) => m.id !== memory.id)]);
      setDetail(memory);
      setOpenId(memory.id);
      setDetailLoading(false);
      notify("New ARCA memory is ready.");
    },
    [notify],
  );

  const onUpdated = useCallback((memory: Memory) => {
    setDetail(memory);
    setMemories((prev) => prev.map((m) => (m.id === memory.id ? summarize(memory) : m)));
  }, []);

  const onDeleted = useCallback((id: string) => {
    setMemories((prev) => prev.filter((m) => m.id !== id));
    setOpenId(null);
    setDetail(null);
  }, []);

  const closeDrawer = useCallback(() => {
    setOpenId(null);
    setDetail(null);
  }, []);

  return (
    <div className="app">
      <TopBar caps={caps} />

      <main className="canvas">
        <section className="arca-hero" aria-labelledby="arca-title">
          <div className="arca-face" aria-hidden="true">
            <span className="face-eye" />
            <span className="face-eye" />
            <span className="face-wave">
              <span />
              <span />
              <span />
              <span />
              <span />
              <span />
              <span />
            </span>
          </div>

          <div className="arca-hero-copy">
            <p className="eyebrow">ARCA Demo</p>
            <h1 id="arca-title">
              A small memory instrument for <em>recordings</em>, transcripts, and action packs.
            </h1>
            <p className="lede">
              Upload or record audio, then ARCA keeps the transcript, summary, decisions, and
              follow-up actions in one calm workspace. Hardware captures can enter through the same
              ingest path.
            </p>
            <div className="hero-actions" aria-label="ARCA capabilities">
              <span>record</span>
              <span>transcribe</span>
              <span>remember</span>
              <span>act</span>
            </div>
          </div>
        </section>

        <div className="grid">
          <Capture onProcessed={onProcessed} />
          <Feed memories={memories} loading={feedLoading} onOpen={openMemory} />
        </div>

        <HardwareBridge />
      </main>

      {openId ? (
        <MemoryDrawer
          memory={detail}
          loading={detailLoading}
          onClose={closeDrawer}
          onUpdated={onUpdated}
          onDeleted={onDeleted}
          notify={notify}
        />
      ) : null}

      {toast ? (
        <div className="toast" role="status" aria-live="polite">
          {toast}
        </div>
      ) : null}
    </div>
  );
}
