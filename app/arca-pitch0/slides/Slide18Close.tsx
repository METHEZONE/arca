"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, fadeIn, blurUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide18Close.module.css";

export default function Slide18Close({ active: _ }: SlideProps) {
  return (
    <section className={`slide slide--center ${s.root}`}>
      <motion.div
        className={s.orb}
        initial={{ opacity: 0, scale: 0.7 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ duration: 2.2, ease: [0.22, 1, 0.36, 1] }}
      />

      <motion.div className={s.stack} variants={stagger(0.5, 0.3)} initial="hidden" animate="show">
        <motion.p variants={fadeUp} className="deck-eyebrow">11:00 PM — again</motion.p>

        <motion.div variants={stagger(0.4, 0.1)} initial="hidden" animate="show" className={s.scene}>
          <motion.p variants={fadeUp} className={s.sceneLine}>Your phone lights up.</motion.p>
          <motion.p variants={fadeUp} className={s.sceneMsg}>
            &ldquo;Send me the quote.&rdquo;
          </motion.p>
          <motion.p variants={fadeUp} className={s.sceneTurn}>
            But this time —{" "}
            <span className="deck-accent">you don&rsquo;t stop.</span>
          </motion.p>
        </motion.div>

        <motion.div
          className={s.heroWrap}
          initial={{ opacity: 0, scale: 0.88, filter: "blur(16px)" }}
          animate={{ opacity: 1, scale: 1, filter: "blur(0px)" }}
          transition={{ delay: 3.0, duration: 1.0, ease: [0.22, 1, 0.36, 1] }}
        >
          <p className={s.hero}>
            Just <span className={s.heroAccent}>arca</span> it.
          </p>
        </motion.div>

        <motion.p variants={blurUp} className={s.slogan}>
          Don&rsquo;t carry it. <span className="deck-accent">Just arca it.</span>
        </motion.p>

        <motion.p
          className={s.footer}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 4.4, duration: 0.9 }}
        >
          ARCA · THE ZONE
        </motion.p>
      </motion.div>
    </section>
  );
}
