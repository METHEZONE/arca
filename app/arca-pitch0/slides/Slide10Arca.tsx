"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, blurUp, scaleIn, EASE_OUT } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide10Arca.module.css";

const ROOTS = [
  { root: "arc", arrow: "→", verb: "connect", delay: 0 },
  { root: "archive", arrow: "→", verb: "remember", delay: 0.12 },
  { root: "ark", arrow: "→", verb: "protect", delay: 0.24 },
];

export default function Slide10Arca(_: SlideProps) {
  return (
    <section className={`slide slide--center slide--glow ${s.root}`}>
      <motion.div
        className={s.stack}
        variants={stagger(0.12, 0.15)}
        initial="hidden"
        animate="show"
      >
        {/* eyebrow */}
        <motion.p variants={fadeUp} className="deck-eyebrow">The companion</motion.p>

        {/* big name */}
        <motion.h1 variants={blurUp} className={s.name}>ARCA</motion.h1>

        {/* root columns */}
        <motion.div
          className={s.roots}
          variants={stagger(0.14, 0.05)}
          initial="hidden"
          animate="show"
        >
          {ROOTS.map((r) => (
            <motion.div key={r.root} variants={fadeUp} className={s.rootCol}>
              <span className={s.rootWord}>{r.root}</span>
              <span className={s.rootArrow}>{r.arrow}</span>
              <span className={s.rootVerb}>{r.verb}</span>
            </motion.div>
          ))}
        </motion.div>

        {/* three verbs resolve */}
        <motion.p
          variants={scaleIn}
          className={s.triad}
        >
          Connect.&ensp;Remember.&ensp;Protect.
        </motion.p>

        {/* the verb moment */}
        <motion.div variants={fadeUp} className={s.verbCard}>
          <span className={s.verbWord}>arca it</span>
          <span className={s.verbDef}>hand it over — completely.</span>
        </motion.div>

        {/* slogan */}
        <motion.p variants={fadeUp} className={s.slogan}>
          Don&rsquo;t carry it. <em>Just arca it.</em>
        </motion.p>
      </motion.div>
    </section>
  );
}
