"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, blurUp, fadeIn, EASE_OUT } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide09Zone.module.css";

const INTERRUPTIONS = [
  { text: "the ping", x: "-38%", y: "-28%", delay: 0.9 },
  { text: '"got a sec?"', x: "36%", y: "-34%", delay: 1.1 },
  { text: "notifications", x: "-42%", y: "24%", delay: 1.3 },
  { text: '"real quick"', x: "38%", y: "30%", delay: 1.0 },
  { text: "where are we on this", x: "-10%", y: "-42%", delay: 1.2 },
];

export default function Slide09Zone(_: SlideProps) {
  return (
    <section className={`slide slide--center slide--glow ${s.root}`}>
      {/* cinematic background image */}
      <motion.div
        className={s.sceneBg}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 1.8, ease: "easeOut" }}
        aria-hidden="true"
      >
        <div className={s.sceneBgImg} />
      </motion.div>
      {/* radial vignette overlay */}
      <div className={s.sceneVignette} aria-hidden="true" />

      {/* breathing orb */}
      <motion.div
        className={s.orb}
        initial={{ opacity: 0, scale: 0.7 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ duration: 1.8, ease: EASE_OUT }}
      />

      {/* interruption words — drift in then dissolve outward */}
      {INTERRUPTIONS.map((item) => (
        <motion.span
          key={item.text}
          className={s.interruptWord}
          style={{ "--ix": item.x, "--iy": item.y } as React.CSSProperties}
          initial={{ opacity: 0, x: item.x, y: item.y }}
          animate={{
            opacity: [0, 0.52, 0.52, 0],
            x: [item.x, item.x, `calc(${item.x} * 1.6)`],
            y: [item.y, item.y, `calc(${item.y} * 1.6)`],
            filter: ["blur(4px)", "blur(0px)", "blur(6px)"],
          }}
          transition={{
            duration: 2.8,
            delay: item.delay,
            times: [0, 0.3, 0.7, 1],
            ease: EASE_OUT,
            repeat: Infinity,
            repeatDelay: 1.4,
          }}
        >
          {item.text}
        </motion.span>
      ))}

      {/* main content */}
      <motion.div
        className={s.stack}
        variants={stagger(0.14, 0.25)}
        initial="hidden"
        animate="show"
      >
        <motion.p variants={fadeUp} className="deck-eyebrow">Our worldview</motion.p>
        <motion.h1 variants={blurUp} className={s.word}>THE ZONE</motion.h1>
        <motion.p variants={fadeUp} className={s.support}>
          The state of deep focus where your most valuable work happens.
        </motion.p>
        <motion.p variants={fadeIn} className={s.enemy}>
          Its one enemy: <span className="deck-accent">interruption.</span>
        </motion.p>
      </motion.div>
    </section>
  );
}
