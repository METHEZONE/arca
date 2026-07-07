import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "ARCA — Live Demo",
  description: "Tap, speak, and watch ARCA turn your words into a filed memory in seconds.",
};

export default function ArcaDemoLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
