import type { ComponentType } from "react";

export type SlideProps = {
  /** true while this slide is the one on stage (drives entrance animations) */
  active: boolean;
};

export type SlideDef = {
  id: string;
  /** short label for the presenter rail / notes */
  title: string;
  Component: ComponentType<SlideProps>;
  /** target narration seconds (from the SCHOOL script) — presenter timing */
  durationSec?: number;
};
