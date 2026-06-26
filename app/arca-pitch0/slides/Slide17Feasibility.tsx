"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, fadeIn } from "../motion";
import { AnimatedNumber } from "../components";
import type { SlideProps } from "./types";
import s from "./Slide17Feasibility.module.css";

const EASE_OUT = [0.22, 1, 0.36, 1] as const;

const TIERS = [
  { label: "Starter", price: "$10", margin: "~85% margin", color: "var(--ink-3)" },
  { label: "Plus",    price: "$15", margin: "~67% margin", color: "var(--accent)" },
  { label: "Pro",     price: "$30", margin: "",            color: "var(--copper)" },
] as const;

const BADGES = ["consent", "retention policy", "on-device option"] as const;

export default function Slide17Feasibility({ active }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.div
        variants={stagger(0.1, 0.15)}
        initial="hidden"
        animate="show"
        className={s.head}
      >
        <motion.p variants={fadeUp} className="deck-eyebrow">It&apos;s real — and the math works</motion.p>
        <motion.h2 variants={fadeUp} className="deck-h2">
          Running today.<br />
          <span className="deck-accent">Early to the category.</span>
        </motion.h2>
      </motion.div>

      <div className={s.body}>
        {/* Zone 1: Pricing tiers */}
        <motion.div
          className={s.zone}
          variants={stagger(0.1, 0.3)}
          initial="hidden"
          animate="show"
        >
          <motion.p variants={fadeUp} className={s.zoneLabel}>Pricing</motion.p>
          <div className={s.tiers}>
            {TIERS.map((t) => (
              <motion.div
                key={t.label}
                variants={fadeUp}
                className={s.tier}
                style={{ "--tier-color": t.color } as React.CSSProperties}
              >
                <span className={s.tierLabel}>{t.label}</span>
                <span className={s.tierPrice}>{t.price}</span>
                {t.margin && <span className={s.tierMargin}>{t.margin}</span>}
              </motion.div>
            ))}
          </div>
          <motion.p variants={fadeIn} className={s.cogsNote}>
            COGS: ElevenLabs Scribe (~$0.22/hr) + Claude
          </motion.p>
        </motion.div>

        {/* Zone 2: Market growth */}
        <motion.div
          className={s.zone}
          variants={stagger(0.1, 0.5)}
          initial="hidden"
          animate="show"
        >
          <motion.p variants={fadeUp} className={s.zoneLabel}>Market</motion.p>
          <div className={s.marketRow}>
            <div className={s.marketNum}>
              <AnimatedNumber value={3.5} decimals={1} prefix="$" suffix="B" play={active} duration={1.4} />
            </div>
            <div className={s.marketArrowWrap}>
              <motion.div
                className={s.marketArrowTrack}
                initial={{ scaleX: 0 }}
                animate={active ? { scaleX: 1 } : { scaleX: 0 }}
                transition={{ duration: 1.3, ease: EASE_OUT, delay: 0.9 }}
              >
                <div className={s.marketArrowFill} />
              </motion.div>
              <svg className={s.arrowHead} viewBox="0 0 12 12" fill="none">
                <path d="M2 6h8M7 2l3 4-3 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </div>
            <div className={s.marketNum}>
              <AnimatedNumber value={21.5} decimals={1} prefix="$" suffix="B" play={active} duration={1.8} />
            </div>
          </div>
          <motion.p variants={fadeUp} className={s.marketCaption}>
            AI assistants for knowledge work · within 5 years
          </motion.p>
        </motion.div>

        {/* Zone 3: Privacy badges */}
        <motion.div
          className={s.zone}
          variants={stagger(0.1, 0.7)}
          initial="hidden"
          animate="show"
        >
          <motion.p variants={fadeUp} className={s.zoneLabel}>Privacy</motion.p>
          <div className={s.badges}>
            {BADGES.map((b) => (
              <motion.span key={b} variants={fadeUp} className={s.badge}>
                {b}
              </motion.span>
            ))}
          </div>
        </motion.div>
      </div>
    </section>
  );
}
