"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide06Voices.module.css";

const QUOTES = [
  {
    text: "“If I step away for a day, the money stops moving.”",
    attr: "— founder, our interviews",
  },
  {
    text: "“My real work doesn’t start until the requests die down at night.”",
    attr: "— founder, our interviews",
  },
];

export default function Slide06Voices({ active: _ }: SlideProps) {
  return (
    <section className={`slide ${s.root}`}>
      <motion.div className={s.col} variants={stagger(0.55, 0.2)} initial="hidden" animate="show">
        <motion.p variants={fadeUp} className="deck-eyebrow">What we heard</motion.p>
        <div className={s.cards}>
          {QUOTES.map((q, i) => (
            <motion.div key={i} variants={fadeUp} className={s.card}>
              <span className={s.glyph} aria-hidden="true">&ldquo;</span>
              <blockquote className={s.quote}>{q.text}</blockquote>
              <cite className={s.attr}>{q.attr}</cite>
            </motion.div>
          ))}
        </div>
      </motion.div>
    </section>
  );
}
