"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, blurUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide01Title.module.css";

export default function Slide01Title(_: SlideProps) {
  return (
    <section className={`slide slide--center slide--glow ${s.root}`}>
      <motion.div
        className={s.orb}
        initial={{ opacity: 0, scale: 0.6 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ duration: 1.6, ease: [0.22, 1, 0.36, 1] }}
      />
      <motion.div className={s.stack} variants={stagger(0.14, 0.25)} initial="hidden" animate="show">
        <motion.p variants={fadeUp} className="deck-eyebrow">THE ZONE · presents</motion.p>
        <motion.h1 variants={blurUp} className={s.word}>ARCA</motion.h1>
        <motion.p variants={fadeUp} className={s.slogan}>
          Don&rsquo;t carry it. <span className="deck-accent">Just arca it.</span>
        </motion.p>
        <motion.div variants={fadeUp} className={s.meta}>
          <span>Group 24 — ARCA</span>
          <span className={s.dot}>·</span>
          <span>Minsung Park</span>
          <span className={s.dot}>·</span>
          <span>Labor &amp; Future of Work</span>
          <span className={s.dot}>·</span>
          <span>Pitch 1 + 2</span>
        </motion.div>
      </motion.div>
    </section>
  );
}
