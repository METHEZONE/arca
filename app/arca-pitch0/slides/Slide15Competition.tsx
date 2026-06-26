"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, fadeIn } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide15Competition.module.css";

const EASE_OUT = [0.22, 1, 0.36, 1] as const;

export default function Slide15Competition({ active }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div
        variants={stagger(0.1, 0.15)}
        initial="hidden"
        animate="show"
        className={s.head}
      >
        <motion.p variants={fadeUp} className="deck-eyebrow">Why we&apos;re different</motion.p>
        <motion.h2 variants={fadeUp} className="deck-h2">
          The only one that <span className="deck-accent">closes the loop.</span>
        </motion.h2>
      </motion.div>

      <div className={s.matrixWrap}>
        {/* Y axis label top */}
        <div className={`${s.axisLabel} ${s.axisTop}`}>PROTECTS YOUR FOCUS</div>
        {/* Y axis label bottom */}
        <div className={`${s.axisLabel} ${s.axisBottom}`}>INTERRUPTS</div>
        {/* X axis label left */}
        <div className={`${s.axisLabel} ${s.axisLeft}`}>SURFACES</div>
        {/* X axis label right */}
        <div className={`${s.axisLabel} ${s.axisRight}`}>COMPLETES</div>

        {/* Axis lines */}
        <div className={s.axisH} />
        <div className={s.axisV} />

        {/* Bottom-left: Note tools */}
        <motion.div
          className={`${s.dot} ${s.dotMuted}`}
          style={{ left: "22%", top: "72%" }}
          initial={{ opacity: 0, scale: 0 }}
          animate={active ? { opacity: 1, scale: 1 } : { opacity: 0, scale: 0 }}
          transition={{ duration: 0.55, ease: EASE_OUT, delay: 0.5 }}
        >
          <span className={s.dotBubble} />
          <span className={s.dotLabel}>Note tools<br /><span className={s.dotSub}>Granola · Otter · CLOVA</span></span>
        </motion.div>

        {/* Middle-low: AI agents */}
        <motion.div
          className={`${s.dot} ${s.dotMuted}`}
          style={{ left: "52%", top: "65%" }}
          initial={{ opacity: 0, scale: 0 }}
          animate={active ? { opacity: 1, scale: 1 } : { opacity: 0, scale: 0 }}
          transition={{ duration: 0.55, ease: EASE_OUT, delay: 0.7 }}
        >
          <span className={s.dotBubble} />
          <span className={s.dotLabel}>AI agents<br /><span className={s.dotSub}>Lindy · Copilot</span></span>
        </motion.div>

        {/* Top-right: Human assistant */}
        <motion.div
          className={`${s.dot} ${s.dotHuman}`}
          style={{ left: "68%", top: "26%" }}
          initial={{ opacity: 0, scale: 0 }}
          animate={active ? { opacity: 1, scale: 1 } : { opacity: 0, scale: 0 }}
          transition={{ duration: 0.55, ease: EASE_OUT, delay: 0.9 }}
        >
          <span className={s.dotBubble} />
          <span className={s.dotLabel}>A human assistant<br /><span className={s.dotSub}>expensive · slow · needs training</span></span>
        </motion.div>

        {/* ARCA — lands last with copper glow */}
        <motion.div
          className={`${s.dot} ${s.dotArca}`}
          style={{ left: "86%", top: "10%" }}
          initial={{ opacity: 0, scale: 0 }}
          animate={active ? { opacity: 1, scale: 1 } : { opacity: 0, scale: 0 }}
          transition={{ duration: 0.7, ease: EASE_OUT, delay: 1.15 }}
        >
          <span className={s.arcaLabel}>ARCA</span>
          <span className={s.arcaBubble} />
        </motion.div>
      </div>

      <motion.p
        variants={fadeIn}
        initial="hidden"
        animate="show"
        className={s.caption}
      >
        The real alternative was hiring someone you trust. ARCA delivers it as software.
      </motion.p>
    </section>
  );
}
