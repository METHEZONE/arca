"use client";

import { useState } from "react";
import { motion } from "framer-motion";
import { fadeUp, stagger } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide13Demo.module.css";

const BEATS = [
  { label: `"send me the quote"`, sub: "request arrives", copper: false },
  { label: "ARCA understands", sub: "who's asking, what they need, that a payment is waiting", copper: false },
  { label: "assembles the reply", sub: "right doc, right numbers", copper: false },
  { label: "tap → arca it → sent", sub: "", copper: true },
  { label: "loop closed", sub: "and I never left the zone", copper: false },
];

export default function Slide13Demo({ active }: SlideProps) {
  const [videoHidden, setVideoHidden] = useState(false);

  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.p
        className="deck-eyebrow"
        variants={fadeUp}
        initial="hidden"
        animate="show"
      >
        Live demo
      </motion.p>

      <div className={s.body}>
        {/* ── device frame ── */}
        <motion.div
          className={s.frameWrap}
          initial={{ opacity: 0, y: 28, scale: 0.97 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ delay: 0.3, duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
        >
          <div className={s.chrome}>
            <div className={s.dots}>
              <span className={s.dot} data-c="close" />
              <span className={s.dot} data-c="min" />
              <span className={s.dot} data-c="max" />
            </div>
            <span className={s.chromeUrl}>arca.app</span>
          </div>

          <div className={s.screen}>
            {/* real video — 404 gracefully, shows placeholder behind it */}
            {/* drop /public/founders/demo.mp4 and it auto-plays */}
            {!videoHidden && (
              <video
                className={s.video}
                src="/media/arca-demo.mp4"
                muted
                loop
                playsInline
                autoPlay
                onError={() => setVideoHidden(true)}
              />
            )}

            {/* placeholder — visible when video is hidden or loading */}
            <div className={s.placeholder} aria-hidden="true">
              <span className={s.playIcon}>▶</span>
              <span className={s.placeholderLabel}>screen recording</span>
              <span className={s.placeholderFile}>demo.mp4</span>
            </div>
          </div>
        </motion.div>

        {/* ── demo beats stepper ── */}
        <motion.ol
          className={s.stepper}
          variants={stagger(0.22, 0.55)}
          initial="hidden"
          animate="show"
        >
          {BEATS.map((beat, i) => (
            <motion.li
              key={i}
              className={`${s.beat} ${beat.copper ? s.beatCopper : ""}`}
              variants={fadeUp}
            >
              <span className={s.beatNum}>{String(i + 1).padStart(2, "0")}</span>
              <span className={s.beatBody}>
                <span className={s.beatLabel}>{beat.label}</span>
                {beat.sub && <span className={s.beatSub}>{beat.sub}</span>}
              </span>
              <motion.span
                className={s.beatDot}
                initial={{ scale: 0 }}
                animate={{ scale: active ? 1 : 0 }}
                transition={{
                  delay: 0.6 + i * 0.22,
                  duration: 0.3,
                  ease: [0.22, 1, 0.36, 1],
                }}
              />
            </motion.li>
          ))}
        </motion.ol>
      </div>
    </section>
  );
}
