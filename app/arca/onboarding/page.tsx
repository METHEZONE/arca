import { Suspense } from "react";
import type { Metadata } from "next";

import { hasGoogleOAuth } from "@/lib/arca/google";
import OnboardingClient from "./OnboardingClient";
import "../arca.css";
import "./onboarding.css";

export const metadata: Metadata = {
  title: "Get started — ARCA",
  description: "Sign in, connect your device, and meet your second self.",
};

export default function OnboardingPage() {
  return (
    <Suspense fallback={<div className="arca-root onb-root" />}>
      <OnboardingClient googleEnabled={hasGoogleOAuth()} />
    </Suspense>
  );
}
