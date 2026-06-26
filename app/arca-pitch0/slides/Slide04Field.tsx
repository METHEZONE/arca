"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, scaleIn, blurUp } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide04Field.module.css";

const cohorts = [
  "Startup founders",
  "Office workers",
  "University students",
  "Hyundai ZER01NE experts",
];

export default function Slide04Field({ active: _active }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div
        className={s.layout}
        variants={stagger(0.1, 0.15)}
        initial="hidden"
        animate="show"
      >
        {/* left: text */}
        <div className={s.left}>
          <motion.p variants={fadeUp} className="deck-eyebrow">
            The field — primary research
          </motion.p>
          <motion.h2 variants={fadeUp} className={`deck-h2 ${s.headline}`}>
            We interviewed 40+ people.{" "}
            <span className="deck-accent">They told us our own story back.</span>
          </motion.h2>

          <motion.div variants={stagger(0.09, 0.55)} initial="hidden" animate="show" className={s.chips}>
            {cohorts.map((c) => (
              <motion.span key={c} variants={fadeUp} className={s.chip}>
                {c}
              </motion.span>
            ))}
          </motion.div>

          <motion.p variants={fadeUp} className={s.caption}>
            Different industries. Different sizes.{" "}
            <span className="deck-accent">The same trap.</span>
          </motion.p>
        </div>

        {/* right: photo collage */}
        <div className={s.collage}>
          <motion.div variants={scaleIn} className={`${s.photoWrap} ${s.photoA}`}>
            <img src="/founders/meetup-1.jpg" alt="Founder meetup — dinner" className={s.photo} />
            <div className={s.photoOverlay} />
          </motion.div>

          <motion.div variants={blurUp} className={`${s.photoWrap} ${s.photoB}`}>
            <img src="/founders/meetup-2.jpg" alt="Founder meetup — cafe" className={s.photo} />
            <div className={s.photoOverlay} />
          </motion.div>

          <motion.div variants={scaleIn} className={`${s.photoWrap} ${s.photoC}`}>
            <img src="/founders/zer01ne-meetup.jpg" alt="ZER01NE networking event" className={s.photo} />
            <div className={s.photoOverlay} />
          </motion.div>
        </div>
      </motion.div>
    </section>
  );
}
