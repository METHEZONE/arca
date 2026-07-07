import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "ARCA OS — Hatch Your Companion",
  description:
    "A short interview, then your companion hatches — a second self with its own name, personality, and memory, ready to take delegations.",
  openGraph: {
    title: "ARCA OS — Hatch Your Companion",
    description: "Answer a few questions. Meet your second self.",
  },
};

export default function ArcaOsLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
