"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp } from "../motion";
import { AnimatedNumber } from "../components";
import type { SlideProps } from "./types";
import s from "./Slide05Numbers.module.css";

export default function Slide05Numbers({ active }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div variants={stagger(0.12, 0.2)} initial="hidden" animate="show" className={s.head}>
        <motion.p variants={fadeUp} className="deck-eyebrow">The data — Microsoft Work Trend Index</motion.p>
        <motion.h2 variants={fadeUp} className="deck-h2">
          More than half of your working life<br />goes to the <span className="deck-accent">traffic around the work.</span>
        </motion.h2>
      </motion.div>

      {/* split bar */}
      <div className={s.bar}>
        <motion.div
          className={s.comm}
          initial={{ width: "0%" }}
          animate={{ width: active ? "57%" : "0%" }}
          transition={{ duration: 1.2, ease: [0.22, 1, 0.36, 1], delay: 0.5 }}
        >
          <span className={s.barLabel}>
            <AnimatedNumber value={57} suffix="%" play={active} duration={1.2} /> communicating
          </span>
        </motion.div>
        <motion.div
          className={s.create}
          initial={{ width: "0%" }}
          animate={{ width: active ? "43%" : "0%" }}
          transition={{ duration: 1.2, ease: [0.22, 1, 0.36, 1], delay: 0.7 }}
        >
          <span className={s.barLabel}>
            <AnimatedNumber value={43} suffix="%" play={active} duration={1.2} /> creating
          </span>
        </motion.div>
      </div>

      <motion.div className={s.chips} variants={stagger(0.14, 1.2)} initial="hidden" animate="show">
        <motion.div variants={fadeUp} className={s.chip}>
          <span className={s.chipNum}><AnimatedNumber value={68} suffix="%" play={active} duration={1.6} /></span>
          <span className={s.chipText}>say they don&rsquo;t have enough uninterrupted focus time</span>
        </motion.div>
        <motion.div variants={fadeUp} className={s.chip}>
          <span className={s.chipNum}><AnimatedNumber value={64} suffix="%" play={active} duration={1.6} /></span>
          <span className={s.chipText}>struggle to find the time &amp; energy to do their actual job</span>
        </motion.div>
      </motion.div>
    </section>
  );
}
