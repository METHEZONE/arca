import type { Metadata } from "next";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { SESSION_COOKIE, verifySession } from "@/lib/arca/session";
import "../arca.css";
import "./app.css";
import AppNav from "./AppNav";

export const metadata: Metadata = {
  title: "ARCA — app",
  description: "Commitment Graph · drag-bounded delegation · evidence-verified closure.",
  robots: { index: false, follow: false },
};

export const dynamic = "force-dynamic";

/**
 * Session gate for the web app. The cookie lives on the arca origin, so when
 * this is reached through thezonebio.com's rewrite there is no session and
 * we bounce to sign-in — which hands the browser to the arca origin.
 */
export default async function AppLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const jar = await cookies();
  const session = await verifySession(jar.get(SESSION_COOKIE)?.value);
  if (!session) redirect("/arca/onboarding?next=app");
  return (
    <div className="arca-root app-root">
      <AppNav email={session.email} />
      <main className="app-main">{children}</main>
    </div>
  );
}
