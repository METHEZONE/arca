import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Min · ARCA Ring",
  description:
    "You just tapped Min's ring. Connect once — we'll both remember when and where we met.",
  openGraph: {
    title: "Min · ARCA Ring",
    description: "Tap. Connect. Remembered forever by ARCA.",
  },
};

export default function RingLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
