// Shared framer-motion variants for ARCA pitch slides.
// Plain data objects — no client boundary needed.
import type { Variants, Transition } from "framer-motion";

export const EASE_OUT: Transition["ease"] = [0.22, 1, 0.36, 1];
export const EASE_IO: Transition["ease"] = [0.65, 0, 0.35, 1];

/* Slide-level enter/exit used by the Deck shell. */
export const slideVariants: Variants = {
  enter: { opacity: 0, scale: 1.04, filter: "blur(14px)" },
  center: {
    opacity: 1,
    scale: 1,
    filter: "blur(0px)",
    transition: { duration: 0.7, ease: EASE_OUT },
  },
  exit: {
    opacity: 0,
    scale: 0.985,
    filter: "blur(10px)",
    transition: { duration: 0.45, ease: EASE_IO },
  },
};

/* Stagger container for sequenced reveals inside a slide. */
export const stagger = (staggerChildren = 0.09, delayChildren = 0.15): Variants => ({
  hidden: {},
  show: { transition: { staggerChildren, delayChildren } },
});

/* Common child reveals. */
export const fadeUp: Variants = {
  hidden: { opacity: 0, y: 26 },
  show: { opacity: 1, y: 0, transition: { duration: 0.66, ease: EASE_OUT } },
};

export const fadeIn: Variants = {
  hidden: { opacity: 0 },
  show: { opacity: 1, transition: { duration: 0.8, ease: EASE_OUT } },
};

export const scaleIn: Variants = {
  hidden: { opacity: 0, scale: 0.9 },
  show: { opacity: 1, scale: 1, transition: { duration: 0.6, ease: EASE_OUT } },
};

export const blurUp: Variants = {
  hidden: { opacity: 0, y: 18, filter: "blur(8px)" },
  show: { opacity: 1, y: 0, filter: "blur(0px)", transition: { duration: 0.75, ease: EASE_OUT } },
};
