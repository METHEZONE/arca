"use client";

import { motion } from "framer-motion";
import type { SlideProps } from "./types";

/** Temporary slide used until the real component is built by the team. */
export function makePlaceholder(label: string, n: string) {
  function Placeholder(_: SlideProps) {
    return (
      <section className="slide slide--center slide--glow">
        <motion.div
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6 }}
          style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 18 }}
        >
          <p className="deck-eyebrow">{n} — building</p>
          <h2 className="deck-h2" style={{ textAlign: "center" }}>{label}</h2>
          <motion.div
            style={{ width: 60, height: 3, background: "var(--accent)", borderRadius: 3 }}
            animate={{ scaleX: [0.4, 1, 0.4] }}
            transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }}
          />
        </motion.div>
      </section>
    );
  }
  return Placeholder;
}
