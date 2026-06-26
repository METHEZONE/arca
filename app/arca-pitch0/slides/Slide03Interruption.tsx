"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, fadeIn } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide03Interruption.module.css";

export default function Slide03Interruption({ active: _ }: SlideProps) {
  return (
    <section className={`slide ${s.root}`}>
      <motion.div
        className={s.light}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 2, ease: "easeOut" }}
      />

      <motion.div className={s.col} variants={stagger(0.45, 0.3)} initial="hidden" animate="show">
        <motion.p variants={fadeUp} className="deck-eyebrow">11:05 PM — five minutes later</motion.p>

        <motion.div
          className={s.phone}
          initial={{ opacity: 0, y: -36, rotate: 1.5 }}
          animate={{ opacity: 1, y: [-36, 8, 0], rotate: [1.5, -1, 0] }}
          transition={{ delay: 0.9, duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
        >
          <span className={s.phoneApp}>● Client</span>
          <span className={s.phoneMsg}>&ldquo;Send the business plan too — we&rsquo;re deciding now.&rdquo;</span>
        </motion.div>

        <motion.div variants={fadeUp} className={s.meterWrap}>
          <span className={s.meterLabel}>FLOW</span>
          <div className={s.meterTrack}>
            <motion.div
              className={s.meterFill}
              initial={{ width: "92%" }}
              animate={{ width: "9%" }}
              transition={{ delay: 1.8, duration: 2.2, ease: [0.65, 0, 0.35, 1] }}
            />
          </div>
          <motion.span
            className={s.meterDraining}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 2.6, duration: 0.5 }}
          >
            draining
          </motion.span>
        </motion.div>

        <motion.div variants={stagger(0.3, 3.4)} initial="hidden" animate="show" className={s.closing}>
          <motion.p variants={fadeIn} className={s.closingLine}>
            None of it was hard.
          </motion.p>
          <motion.p variants={fadeIn} className={s.closingAccent}>
            I just had no one I trusted{" "}
            <span className="deck-accent">to do it right.</span>
          </motion.p>
        </motion.div>
      </motion.div>
    </section>
  );
}
