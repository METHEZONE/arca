"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide16Moats.module.css";

const EASE_OUT = [0.22, 1, 0.36, 1] as const;

const MOATS = [
  {
    num: "01",
    title: "Completion",
    body: "we measure one thing: loops closed — not notes taken",
    accent: "var(--accent)",
    glow: "rgba(255, 122, 26, 0.18)",
  },
  {
    num: "02",
    title: "The verb",
    body: '"arca it" like "google it" — a habit beats a feature',
    accent: "var(--copper)",
    glow: "rgba(220, 80, 0, 0.18)",
  },
  {
    num: "03",
    title: "The marketplace",
    body: "users build & share delegation agents — a network a better model can't copy",
    accent: "#8b9cf7",
    glow: "rgba(139, 156, 247, 0.14)",
  },
] as const;

export default function Slide16Moats({ active }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div
        variants={stagger(0.1, 0.15)}
        initial="hidden"
        animate="show"
        className={s.head}
      >
        <motion.p variants={fadeUp} className="deck-eyebrow">The moat</motion.p>
        <motion.h2 variants={fadeUp} className="deck-h2">
          The technology isn&apos;t the moat.<br />
          <span className="deck-accent">These are.</span>
        </motion.h2>
      </motion.div>

      <div className={s.pillars}>
        {MOATS.map((m, i) => (
          <motion.div
            key={m.num}
            className={s.pillar}
            style={{ "--pillar-accent": m.accent, "--pillar-glow": m.glow } as React.CSSProperties}
            initial={{ opacity: 0, y: 60 }}
            animate={active ? { opacity: 1, y: 0 } : { opacity: 0, y: 60 }}
            transition={{ duration: 0.72, ease: EASE_OUT, delay: 0.45 + i * 0.16 }}
          >
            <span className={s.pillarNum}>{m.num}</span>
            <span className={s.pillarTitle}>{m.title}</span>
            <span className={s.pillarBody}>{m.body}</span>
          </motion.div>
        ))}
      </div>
    </section>
  );
}
