"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, blurUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide14Validation.module.css";

const checkItems = [
  "Validated the core flow — they wanted exactly this: a conversation, turned into ready-to-go actions.",
  "The triage design — 2–3 options, low-risk handled automatically — matched what they asked for.",
  "Sharpest feedback: narrow it. So we did — to one line.",
];

export default function Slide14Validation({ active: _active }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div
        className={s.layout}
        variants={stagger(0.1, 0.15)}
        initial="hidden"
        animate="show"
      >
        {/* left: photo */}
        <motion.div variants={blurUp} className={s.photoSide}>
          <div className={s.photoWrap}>
            <img
              src="/founders/zer01ne-meetup.jpg"
              alt="ZER01NE networking event"
              className={s.photo}
            />
            <div className={s.photoOverlay} />
          </div>
        </motion.div>

        {/* right: content */}
        <div className={s.right}>
          <motion.p variants={fadeUp} className="deck-eyebrow">
            We tested it
          </motion.p>
          <motion.h2 variants={fadeUp} className={`deck-h2 ${s.headline}`}>
            Real users. Real sessions.{" "}
            <span className="deck-accent">Real signal.</span>
          </motion.h2>

          <motion.ul
            className={s.checklist}
            variants={stagger(0.16, 0.55)}
            initial="hidden"
            animate="show"
          >
            {checkItems.map((item, i) => (
              <motion.li key={i} variants={fadeUp} className={s.checkItem}>
                <span className={s.checkIcon} aria-hidden="true">✓</span>
                <span className={s.checkText}>{item}</span>
              </motion.li>
            ))}
          </motion.ul>

          <motion.div variants={fadeUp} className={s.callout}>
            <p className={s.calloutLabel}>One-line definition</p>
            <p className={s.calloutQuote}>
              &ldquo;The AI that remembers your conversations and turns them into your next action.&rdquo;
            </p>
          </motion.div>
        </div>
      </motion.div>
    </section>
  );
}
