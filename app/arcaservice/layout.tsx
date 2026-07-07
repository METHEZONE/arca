import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "ARCA — How the Service Works",
  description:
    "The ARCA loop, end to end: capture, understand, classify, decide, act, confirm, remember, pre-brief.",
};

export default function ArcaServiceLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
