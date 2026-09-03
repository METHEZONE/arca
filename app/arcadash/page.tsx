"use client";

import { useEffect, useState } from "react";

/// The owner's beta desk. Applications arrive by email/Slack (there is no
/// database on this deployment); approving one means minting a signed
/// download link here and sending it. The admin token is kept in this
/// browser only.
export default function ArcaDash() {
  const [token, setToken] = useState("");
  const [email, setEmail] = useState("");
  const [days, setDays] = useState(14);
  const [link, setLink] = useState<string | null>(null);
  const [expires, setExpires] = useState<string | null>(null);
  const [phase, setPhase] = useState<"idle" | "busy" | "error">("idle");
  const [error, setError] = useState("");
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    setToken(window.localStorage.getItem("arcadash-token") ?? "");
  }, []);

  async function mint(e: React.FormEvent) {
    e.preventDefault();
    setPhase("busy");
    setError("");
    setLink(null);
    window.localStorage.setItem("arcadash-token", token);
    try {
      const res = await fetch("/api/arca/beta/link", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ email, days }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
      setLink(data.link);
      setExpires(data.expiresAt);
      setPhase("idle");
    } catch (err) {
      setError((err as Error).message);
      setPhase("error");
    }
  }

  const mailto = link
    ? `mailto:${email}?subject=${encodeURIComponent("ARCA 베타 다운로드 링크")}&body=${encodeURIComponent(
        `안녕하세요! ARCA macOS 베타 링크입니다 (14일 유효).\n\n${link}\n\n설치: zip 풀고 응용 프로그램으로 이동 → 첫 실행은 오른쪽 클릭 › 열기.\n온보딩에서 본인 Anthropic API 키를 넣어주세요 (console.anthropic.com).\n\niPhone은 TestFlight: https://testflight.apple.com/join/U78MNCxj\n\n— 박민성`
      )}`
    : "";

  return (
    <main style={{ fontFamily: "-apple-system, Pretendard, sans-serif", background: "#0b0d14", color: "#f4f1ea", minHeight: "100vh", padding: "56px 20px" }}>
      <div style={{ maxWidth: 640, margin: "0 auto", display: "grid", gap: 20 }}>
        <div>
          <p style={{ letterSpacing: 3, fontSize: 11, fontWeight: 800, color: "#ff7a1a", margin: 0 }}>ARCA DASH</p>
          <h1 style={{ fontSize: 30, margin: "6px 0 4px" }}>베타 승인</h1>
          <p style={{ opacity: 0.6, margin: 0, lineHeight: 1.6 }}>
            신청은 메일·슬랙으로 도착합니다. 여기서 이메일을 넣으면 그 사람 전용 다운로드 링크(HMAC 서명, 기본 14일)가 만들어져요.
            서명 비밀키를 바꾸면 모든 링크가 한 번에 무효화됩니다.
          </p>
        </div>

        <form onSubmit={mint} style={{ display: "grid", gap: 10, background: "rgba(255,255,255,0.05)", padding: 18, borderRadius: 16 }}>
          <label style={{ fontSize: 12, opacity: 0.6 }}>관리자 토큰 (이 브라우저에만 저장)</label>
          <input type="password" value={token} onChange={(e) => setToken(e.target.value)} placeholder="ARCA_ADMIN_TOKEN" required style={inputStyle} />
          <label style={{ fontSize: 12, opacity: 0.6 }}>신청자 이메일</label>
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="tester@example.com" required style={inputStyle} />
          <label style={{ fontSize: 12, opacity: 0.6 }}>유효 기간 (일)</label>
          <input type="number" min={1} max={90} value={days} onChange={(e) => setDays(Number(e.target.value))} style={{ ...inputStyle, width: 120 }} />
          <button type="submit" disabled={phase === "busy"} style={btnStyle}>
            {phase === "busy" ? "…" : "다운로드 링크 만들기"}
          </button>
          {error && <p style={{ color: "#ffb36b", margin: 0 }}>{error}</p>}
        </form>

        {link && (
          <div style={{ display: "grid", gap: 10, background: "rgba(82,219,115,0.08)", border: "1px solid rgba(82,219,115,0.35)", padding: 18, borderRadius: 16 }}>
            <p style={{ margin: 0, fontWeight: 700 }}>승인 링크 · {expires ? new Date(expires).toLocaleDateString("ko-KR") : ""}까지</p>
            <code style={{ wordBreak: "break-all", fontSize: 12, opacity: 0.85 }}>{link}</code>
            <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
              <button
                type="button"
                style={btnStyle}
                onClick={async () => {
                  await navigator.clipboard.writeText(link);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 1500);
                }}
              >
                {copied ? "복사했어요" : "링크 복사"}
              </button>
              <a href={mailto} style={{ ...btnStyle, background: "rgba(255,255,255,0.1)", color: "#fff", textDecoration: "none" }}>
                메일 초안 열기
              </a>
            </div>
          </div>
        )}

        <div style={{ opacity: 0.55, fontSize: 13, lineHeight: 1.7 }}>
          <p style={{ margin: 0 }}>iPhone/Watch는 승인 없이 TestFlight 공개 링크로: https://testflight.apple.com/join/U78MNCxj</p>
          <p style={{ margin: 0 }}>Mac 빌드 파일은 ARCA_BETA_ZIP_URL(GitHub Releases)에서 내려갑니다. 새 빌드를 올리면 링크는 그대로 최신을 가리킵니다.</p>
        </div>
      </div>
    </main>
  );
}

const inputStyle: React.CSSProperties = {
  background: "rgba(255,255,255,0.06)",
  border: "1px solid rgba(255,255,255,0.12)",
  color: "#fff",
  padding: "10px 12px",
  borderRadius: 10,
  fontSize: 14,
};
const btnStyle: React.CSSProperties = {
  background: "#ff7a1a",
  color: "#000",
  border: 0,
  padding: "10px 16px",
  borderRadius: 999,
  fontWeight: 800,
  cursor: "pointer",
};
