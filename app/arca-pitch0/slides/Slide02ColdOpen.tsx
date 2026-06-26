"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide02ColdOpen.module.css";

const LINES = ["Everyone's gone home.", "It's finally quiet.", "And I'm in the zone."];

export default function Slide02ColdOpen(_: SlideProps) {
  return (
    <section className={`slide ${s.root}`}>
      {/* cinematic background image */}
      <motion.div
        className={s.sceneBg}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 1.5, ease: "easeOut" }}
        aria-hidden="true"
      >
        <div className={s.sceneBgImg} />
      </motion.div>
      {/* dark gradient overlay for text legibility */}
      <div className={s.sceneOverlay} aria-hidden="true" />

      <motion.div
        className={s.light}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 2, ease: "easeOut" }}
      />

      <motion.div className={s.col} variants={stagger(0.5, 0.4)} initial="hidden" animate="show">
        <motion.p variants={fadeUp} className="deck-eyebrow">11:00 PM — the best 90 minutes of my week</motion.p>
        <div className={s.lines}>
          {LINES.map((l) => (
            <motion.p key={l} variants={fadeUp} className={s.line}>{l}</motion.p>
          ))}
        </div>

        <motion.div
          className={s.phone}
          initial={{ opacity: 0, y: 40, rotate: -2 }}
          animate={{ opacity: 1, y: [40, -6, 0], rotate: [-2, 1.5, 0] }}
          transition={{ delay: 2.6, duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
        >
          <span className={s.phoneApp}>● Client</span>
          <span className={s.phoneMsg}>&ldquo;Send me the quote. Now — we&rsquo;ll wire the payment today.&rdquo;</span>
        </motion.div>

        <motion.p
          className={s.caption}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 3.5, duration: 0.8 }}
        >
          45 minutes to get in. <span className="deck-accent">One second to lose it.</span>
        </motion.p>
      </motion.div>
    </section>
  );
}
