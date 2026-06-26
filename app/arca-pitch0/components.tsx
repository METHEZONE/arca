"use client";

import { useEffect, useRef, useState } from "react";
import { EASE_OUT } from "./motion";

/* Count-up number that runs when `play` flips true. */
export function useCountUp(target: number, { duration = 1.4, play = true, decimals = 0 } = {}) {
  const [val, setVal] = useState(0);
  const raf = useRef<number | null>(null);
  useEffect(() => {
    if (!play) { setVal(0); return; }
    const reduce = typeof window !== "undefined"
      && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduce) { setVal(target); return; }
    const start = performance.now();
    const ease = (t: number) => 1 - Math.pow(1 - t, 3); // easeOutCubic
    const tick = (now: number) => {
      const p = Math.min(1, (now - start) / (duration * 1000));
      const v = target * ease(p);
      setVal(decimals ? parseFloat(v.toFixed(decimals)) : Math.round(v));
      if (p < 1) raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
    return () => { if (raf.current) cancelAnimationFrame(raf.current); };
  }, [target, duration, play, decimals]);
  return val;
}

export function AnimatedNumber({
  value, duration = 1.4, decimals = 0, prefix = "", suffix = "", play = true, className,
}: {
  value: number; duration?: number; decimals?: number;
  prefix?: string; suffix?: string; play?: boolean; className?: string;
}) {
  const v = useCountUp(value, { duration, play, decimals });
  return <span className={className}>{prefix}{v.toLocaleString()}{suffix}</span>;
}

export const EASE = EASE_OUT;
