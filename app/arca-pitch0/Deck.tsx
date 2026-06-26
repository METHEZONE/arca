"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { slideVariants } from "./motion";
import type { SlideDef } from "./slides/types";

export default function Deck({ slides, tag = "ARCA · TAP4001" }: { slides: SlideDef[]; tag?: string }) {
  const [i, setI] = useState(0);
  const [dir, setDir] = useState(1);
  const [auto, setAuto] = useState(false);
  const [present, setPresent] = useState(false);
  const n = slides.length;
  const iRef = useRef(0);
  iRef.current = i;

  const go = useCallback((next: number) => {
    const clamped = Math.max(0, Math.min(n - 1, next));
    setDir(clamped >= iRef.current ? 1 : -1);
    setI(clamped);
  }, [n]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (["ArrowRight", " ", "PageDown", "Enter"].includes(e.key)) { e.preventDefault(); go(iRef.current + 1); }
      else if (["ArrowLeft", "PageUp", "Backspace"].includes(e.key)) { e.preventDefault(); go(iRef.current - 1); }
      else if (e.key === "Home") go(0);
      else if (e.key === "End") go(n - 1);
      else if (e.key === "f") document.documentElement.requestFullscreen?.();
      else if (e.key === "a" || e.key === "A") setAuto((v) => !v);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [go, n]);

  // autoplay: hold each slide for its narration duration, then advance
  useEffect(() => {
    if (!auto || i >= n - 1) return;
    const ms = Math.max(slides[i].durationSec ?? 6, 4) * 1000;
    const t = setTimeout(() => go(i + 1), ms);
    return () => clearTimeout(t);
  }, [auto, i, n, go, slides]);

  // deep-link & modes: ?slide=N jumps, ?present=1 hides chrome, ?autoplay=1 starts autoplay
  useEffect(() => {
    const sp = new URLSearchParams(window.location.search);
    const p = sp.get("slide");
    if (p != null) {
      const k = parseInt(p, 10);
      if (!Number.isNaN(k)) setI(Math.max(0, Math.min(n - 1, k)));
    }
    if (sp.get("present") === "1") setPresent(true);
    if (sp.get("autoplay") === "1") setAuto(true);
  }, [n]);

  const Current = slides[i].Component;
  const pct = ((i + 1) / n) * 100;

  return (
    <div className="deck-root">
      {!present && <div className="deck-tag">{tag}</div>}
      {!present && (
        <div className="deck-counter">
          {auto && <span className="deck-auto">● AUTO</span>}
          <b>{String(i + 1).padStart(2, "0")}</b> / {String(n).padStart(2, "0")}
        </div>
      )}

      {!present && auto && i < n - 1 && (
        <motion.div
          key={`cd-${i}`}
          className="deck-countdown"
          initial={{ width: "0%" }}
          animate={{ width: "100%" }}
          transition={{ duration: Math.max(slides[i].durationSec ?? 6, 4), ease: "linear" }}
        />
      )}

      <div className="deck-stage">
        <AnimatePresence mode="wait" custom={dir}>
          <motion.div
            key={slides[i].id}
            className="deck-frame"
            variants={slideVariants}
            initial="enter"
            animate="center"
            exit="exit"
          >
            <Current active />
          </motion.div>
        </AnimatePresence>
      </div>

      {!present && <div className="deck-zone deck-zone--prev" onClick={() => go(i - 1)} aria-label="previous slide" />}
      {!present && <div className="deck-zone deck-zone--next" onClick={() => go(i + 1)} aria-label="next slide" />}

      {!present && (
        <div className="deck-navhint">
          <span className="deck-key">←</span><span className="deck-key">→</span>
          <span className="deck-key">A</span><span>auto {auto ? "on" : "off"}</span>
          <span className="deck-key">F</span>
          <span>· {slides[i].title}</span>
        </div>
      )}
      {!present && <div className="deck-progress" style={{ width: `${pct}%` }} />}
    </div>
  );
}
