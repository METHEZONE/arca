import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "ARCA — Your Second Self",
  description:
    "ARCA is an AGI companion that remembers everything — every meeting, every person, every decision — and does the work you delegate with two words: arca it.",
  openGraph: {
    title: "ARCA — Your Second Self",
    description: "An AGI companion OS that remembers everything, so you don't have to.",
  },
};

export default function ArcaLandingLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
