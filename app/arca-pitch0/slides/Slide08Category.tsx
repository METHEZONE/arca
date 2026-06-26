"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, scaleIn } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide08Category.module.css";

const CARDS = [
  {
    label: "Second brain",
    sub: "stores more",
    highlight: false,
  },
  {
    label: "Second self",
    sub: "clones you",
    highlight: false,
  },
  {
    label: "Handoff",
    sub: "gives the task away — completely",
    highlight: true,
  },
] as const;

export default function Slide08Category({ active: _ }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div
        className={s.inner}
        variants={stagger(0.1, 0.15)}
        initial="hidden"
        animate="show"
      >
        {/* eyebrow */}
        <motion.p variants={fadeUp} className="deck-eyebrow">
          A different category
        </motion.p>

        {/* card row */}
        <motion.div className={s.cards} variants={stagger(0.18, 0.3)}>
          {CARDS.map((card) => (
            <motion.div
              key={card.label}
              className={`${s.card} ${card.highlight ? s.cardHighlight : s.cardMuted}`}
              variants={
                card.highlight
                  ? {
                      hidden: { opacity: 0, scale: 0.88, y: 20 },
                      show: {
                        opacity: 1,
                        scale: 1.05,
                        y: 0,
                        transition: {
                          duration: 0.75,
                          ease: [0.22, 1, 0.36, 1],
                          delay: 0.12,
                        },
                      },
                    }
                  : scaleIn
              }
            >
              <span className={`${s.cardLabel} ${card.highlight ? s.cardLabelHl : ""}`}>
                {card.label}
              </span>
              <span className={`${s.cardSub} ${card.highlight ? s.cardSubHl : ""}`}>
                {card.sub}
              </span>
            </motion.div>
          ))}
        </motion.div>

        {/* closing serif line */}
        <motion.p variants={fadeUp} className={s.closing}>
          ARCA owns the handoff category.
        </motion.p>
      </motion.div>
    </section>
  );
}
