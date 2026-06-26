"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, fadeIn, scaleIn, EASE_OUT } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide11TwoModes.module.css";

/* Incoming request chips that get deflected */
const CHIPS = [
  { text: "send the quote", fromX: "-180%", fromY: "-20%", toX: "-220%", toY: "-80%" },
  { text: "where are we?",  fromX: "-200%", fromY: "30%",  toX: "-260%", toY: "90%"  },
  { text: "sign this",      fromX: "-160%", fromY: "70%",  toX: "-200%", toY: "140%" },
  { text: "got a sec?",     fromX: "-190%", fromY: "-60%", toX: "-230%", toY: "-120%" },
];

/* Triage queue cards */
const QUEUE_CARDS = [
  { label: "Quote request", from: "Client A", tag: "arca it", resolved: true },
  { label: "Status update", from: "PM Slack", tag: "arca it", resolved: false },
  { label: "Contract sign",  from: "Legal",   tag: "decide",  resolved: false },
];

const OPTIONS = ["Reply with update", "Schedule a call", "Delegate to Alex"];

export default function Slide11TwoModes({ active }: SlideProps) {
  return (
    <section className={`slide ${s.root}`}>
      {/* eyebrow + title row */}
      <motion.div
        className={s.head}
        variants={stagger(0.1, 0.1)}
        initial="hidden"
        animate="show"
      >
        <motion.p variants={fadeUp} className="deck-eyebrow">
          How it works — two modes, because you have two modes
        </motion.p>
      </motion.div>

      {/* split panels */}
      <div className={s.split}>
        {/* ── LEFT: IN THE ZONE ── */}
        <motion.div
          className={s.panel}
          variants={stagger(0.12, 0.3)}
          initial="hidden"
          animate="show"
        >
          <motion.div variants={fadeUp} className={s.panelLabel}>
            <span className={s.labelDot} />
            IN THE ZONE
          </motion.div>

          {/* shield arena */}
          <motion.div variants={scaleIn} className={s.shieldArena}>
            {/* ambient glow behind shield */}
            <div className={s.shieldGlow} />

            {/* shield hexagon */}
            <motion.div
              className={s.shield}
              initial={{ opacity: 0, scale: 0.6 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ delay: 0.5, duration: 0.9, ease: EASE_OUT }}
            >
              <span className={s.shieldIcon}>⬡</span>
              <span className={s.shieldText}>ARCA</span>
            </motion.div>

            {/* deflecting chips */}
            {CHIPS.map((chip, i) => (
              <motion.div
                key={chip.text}
                className={s.incomingChip}
                initial={{ opacity: 0, x: chip.fromX, y: chip.fromY }}
                animate={active ? {
                  opacity:    [0, 1,    1,    0   ],
                  x:          [chip.fromX, "0%", chip.toX,  chip.toX ],
                  y:          [chip.fromY, "0%", chip.toY,  chip.toY ],
                  scale:      [0.8, 1,   1,    0.6 ],
                  rotate:     [0,   0,   i % 2 === 0 ? 18 : -18, i % 2 === 0 ? 28 : -28],
                } : { opacity: 0 }}
                transition={{
                  duration: 2.2,
                  delay: 0.7 + i * 0.35,
                  times:  [0, 0.38, 0.62, 1],
                  ease: EASE_OUT,
                  repeat: Infinity,
                  repeatDelay: 1.8,
                }}
              >
                {chip.text}
              </motion.div>
            ))}
          </motion.div>

          <motion.p variants={fadeUp} className={s.caption}>
            ARCA stands guard. Requests are handled silently.{" "}
            <span className={s.calm}>You&rsquo;re never interrupted.</span>
          </motion.p>
        </motion.div>

        {/* ── copper divider ── */}
        <motion.div
          className={s.divider}
          initial={{ scaleY: 0 }}
          animate={{ scaleY: 1 }}
          transition={{ delay: 0.4, duration: 0.9, ease: EASE_OUT }}
        />

        {/* ── RIGHT: OUT OF THE ZONE ── */}
        <motion.div
          className={s.panel}
          variants={stagger(0.13, 0.55)}
          initial="hidden"
          animate="show"
        >
          <motion.div variants={fadeUp} className={`${s.panelLabel} ${s.panelLabelRight}`}>
            <span className={`${s.labelDot} ${s.labelDotRight}`} />
            OUT OF THE ZONE
          </motion.div>

          {/* triage queue */}
          <motion.div variants={fadeIn} className={s.queue}>
            {QUEUE_CARDS.map((card, i) => (
              <motion.div
                key={card.label}
                className={`${s.queueCard} ${card.resolved ? s.queueCardResolved : ""}`}
                initial={{ opacity: 0, x: 60, y: -10 }}
                animate={active
                  ? card.resolved
                    ? { opacity: [0, 1, 1, 0], x: [60, 0, 80], y: [-10, 0, -40], scale: [0.9, 1, 0.8] }
                    : { opacity: 1, x: 0, y: 0 }
                  : { opacity: 0, x: 60 }}
                transition={card.resolved
                  ? { delay: 1.1 + i * 0.2, duration: 1.8, times: [0, 0.3, 0.7, 1], ease: EASE_OUT }
                  : { delay: 1.1 + i * 0.2, duration: 0.7, ease: EASE_OUT }}
              >
                <div className={s.cardRow}>
                  <div>
                    <p className={s.cardLabel}>{card.label}</p>
                    <p className={s.cardFrom}>{card.from}</p>
                  </div>
                  <span className={`${s.cardTag} ${card.tag === "arca it" ? s.cardTagArca : s.cardTagDecide}`}>
                    {card.resolved ? "loop closed ✓" : card.tag}
                  </span>
                </div>
              </motion.div>
            ))}

            {/* decision card with 1-2-3 options */}
            <motion.div
              className={s.decisionCard}
              initial={{ opacity: 0, y: 20 }}
              animate={active ? { opacity: 1, y: 0 } : { opacity: 0, y: 20 }}
              transition={{ delay: 1.7, duration: 0.8, ease: EASE_OUT }}
            >
              <p className={s.decisionTitle}>Contract sign</p>
              <div className={s.options}>
                {OPTIONS.map((opt, i) => (
                  <motion.div
                    key={opt}
                    className={`${s.option} ${i === 1 ? s.optionHighlighted : ""}`}
                    initial={{ opacity: 0, x: 20 }}
                    animate={active ? { opacity: 1, x: 0 } : { opacity: 0, x: 20 }}
                    transition={{ delay: 2.0 + i * 0.14, duration: 0.55, ease: EASE_OUT }}
                  >
                    <span className={s.optionNum}>{i + 1}</span>
                    <span className={s.optionText}>{opt}</span>
                    {i === 1 && (
                      <motion.span
                        className={s.optionBadge}
                        initial={{ scale: 0 }}
                        animate={active ? { scale: 1 } : { scale: 0 }}
                        transition={{ delay: 2.5, duration: 0.4, ease: EASE_OUT }}
                      >
                        recommended
                      </motion.span>
                    )}
                  </motion.div>
                ))}
              </div>
              <motion.div
                className={s.tapHint}
                initial={{ opacity: 0 }}
                animate={active ? { opacity: 1 } : { opacity: 0 }}
                transition={{ delay: 2.8, duration: 0.6 }}
              >
                one tap
              </motion.div>
            </motion.div>
          </motion.div>

          <motion.p variants={fadeUp} className={s.caption}>
            You surface. Triage in seconds:{" "}
            <span className="deck-accent">arca it</span>, or decide with one tap.
          </motion.p>
        </motion.div>
      </div>
    </section>
  );
}
