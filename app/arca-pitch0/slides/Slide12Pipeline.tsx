"use client";

import { motion } from "framer-motion";
import { stagger, fadeUp, scaleIn } from "../motion";
import type { SlideProps } from "./types";
import s from "./Slide12Pipeline.module.css";

const NODES = [
  {
    glyph: "◎",
    title: "Capture",
    detail: "speaker-separated transcript (ElevenLabs Scribe) — knows who asked for what",
  },
  {
    glyph: "⊞",
    title: "Action Pack",
    detail: "not a summary — extracted to-dos, a drafted reply, a calendar entry",
  },
  {
    glyph: "⇥",
    title: "Execute",
    detail: "pushed into Slack, Notion, your docs",
  },
  {
    glyph: "↺",
    title: "Reflect",
    detail: "weekly recap: where time went, what pulled you out",
  },
];

const NODE_DELAY = 0.18; // seconds between each node reveal
const LINE_DELAY = 0.32; // connector starts slightly after node

export default function Slide12Pipeline({ active }: SlideProps) {
  return (
    <section className={`slide slide--glow ${s.root}`}>
      <motion.p
        className="deck-eyebrow"
        variants={fadeUp}
        initial="hidden"
        animate="show"
      >
        Under the hood
      </motion.p>

      <div className={s.flow}>
        {NODES.map((node, i) => (
          <div key={node.title} className={s.step}>
            {/* node card */}
            <motion.div
              className={s.node}
              variants={scaleIn}
              initial="hidden"
              animate="show"
              transition={{ delay: 0.3 + i * NODE_DELAY * 2, duration: 0.55, ease: [0.22, 1, 0.36, 1] }}
            >
              <span className={s.glyph}>{node.glyph}</span>
              <strong className={s.nodeTitle}>{node.title}</strong>
              <p className={s.nodeDetail}>{node.detail}</p>
            </motion.div>

            {/* connector line between nodes (not after the last) */}
            {i < NODES.length - 1 && (
              <div className={s.connWrap}>
                <motion.div
                  className={s.conn}
                  initial={{ scaleX: 0 }}
                  animate={{ scaleX: active ? 1 : 0 }}
                  transition={{
                    delay: 0.3 + i * NODE_DELAY * 2 + LINE_DELAY,
                    duration: 0.5,
                    ease: [0.22, 1, 0.36, 1],
                  }}
                  style={{ originX: 0 }}
                />
                <motion.div
                  className={s.connArrow}
                  initial={{ opacity: 0, x: -6 }}
                  animate={{ opacity: active ? 1 : 0, x: active ? 0 : -6 }}
                  transition={{
                    delay: 0.3 + i * NODE_DELAY * 2 + LINE_DELAY + 0.4,
                    duration: 0.25,
                  }}
                >
                  ›
                </motion.div>
              </div>
            )}
          </div>
        ))}
      </div>

      <motion.p
        className={s.closing}
        initial={{ opacity: 0, y: 14 }}
        animate={{ opacity: active ? 1 : 0, y: active ? 0 : 14 }}
        transition={{ delay: 1.6, duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
      >
        It doesn&rsquo;t just record your work &mdash;{" "}
        <span className="deck-accent">it completes it.</span>
      </motion.p>
    </section>
  );
}
