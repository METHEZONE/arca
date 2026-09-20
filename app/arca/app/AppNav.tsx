"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const LINKS = [
  { href: "/arca/app", label: "약속" },
  { href: "/arca/app/capture", label: "캡처" },
  { href: "/arca/app/a2a", label: "ARCA ↔ ARCA" },
];

export default function AppNav({ email }: { email: string }) {
  const path = usePathname();
  return (
    <nav className="app-nav">
      <Link className="a-logo" href="/arca/app">
        arca
      </Link>
      <div className="app-nav-links">
        {LINKS.map((l) => (
          <Link key={l.href} href={l.href} className={path === l.href || (l.href !== "/arca/app" && path.startsWith(l.href)) ? "on" : ""}>
            {l.label}
          </Link>
        ))}
      </div>
      <div className="app-nav-me">
        <span className="mut">{email}</span>
        <a href="/arca/app/onboarding" className="mut">
          프로필
        </a>
        <a href="/api/arca/auth/logout" className="mut">
          로그아웃
        </a>
      </div>
    </nav>
  );
}
