"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, blurUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide07Bottleneck.module.css";

export default function Slide07Bottleneck({ active: _ }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div
        className={s.inner}
        variants={stagger(0.11, 0.15)}
        initial="hidden"
        animate="show"
      >
        {/* eyebrow */}
        <motion.p variants={fadeUp} className="deck-eyebrow">
          The reframe
        </motion.p>

        {/* hero heading */}
        <motion.h1 variants={blurUp} className={`deck-h1 ${s.hero}`}>
          The bottleneck isn&rsquo;t your tools.
          <br />
          It&rsquo;s a person —{" "}
          <motion.span
            className={`deck-accent ${s.emphasis}`}
            variants={{
              hidden: { opacity: 0, x: -12, filter: "blur(10px)" },
              show: {
                opacity: 1,
                x: 0,
                filter: "blur(0px)",
                transition: { duration: 0.85, ease: [0.22, 1, 0.36, 1], delay: 0.55 },
              },
            }}
          >
            it&rsquo;s you.
          </motion.span>
        </motion.h1>

        {/* non-solutions row */}
        <motion.div className={s.nonSolutions} variants={stagger(0.13, 0.6)}>
          {["better notes", "more reminders", "a smarter to-do list"].map((label) => (
            <motion.div
              key={label}
              className={s.strike}
              variants={{
                hidden: { opacity: 0, y: 14 },
                show: {
                  opacity: 1,
                  y: 0,
                  transition: { duration: 0.55, ease: [0.22, 1, 0.36, 1] },
                },
              }}
            >
              <span className={s.strikeText}>{label}</span>
            </motion.div>
          ))}
        </motion.div>

        {/* supporting line */}
        <motion.p
          variants={fadeUp}
          className={`deck-lead ${s.support}`}
        >
          A summary never finishes the work.{" "}
          <span className={s.muted}>A reminder never sends the quote.</span>
        </motion.p>
      </motion.div>
    </section>
  );
}
