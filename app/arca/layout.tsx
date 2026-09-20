import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "ARCA — 약속을, 현실이 될 때까지 · Personal Life OS",
  description:
    "ARCA는 회의와 일상 대화에서 약속을 감지하고, 당신이 그은 범위 안에서만 움직이고, 바깥 세상의 증거가 생겨야 끝났다고 말하는 Personal Life OS입니다. 받아쓰는 AI는 많습니다. 끝내는 AI는 없습니다.",
  openGraph: {
    title: "ARCA — 약속을, 현실이 될 때까지",
    description:
      "From fragmented tasks to a living model of your life. From generic intelligence to your definition of good. From prompted assistance to proactive orchestration.",
  },
};

export default function ArcaLandingLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
