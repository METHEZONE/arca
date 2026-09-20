"use client";

import type { Taste } from "./client";

export function SourcesPanel() {
  const rows: Array<{ name: string; state: "live" | "proto" | "next"; note: string }> = [
    { name: "Google 계정", state: "live", note: "로그인 · 연결됨" },
    { name: "웹 캡처 (붙여넣기 · 브라우저 녹음)", state: "live", note: "전사 · 약속 감지" },
    { name: "Mac 베타 앱", state: "live", note: "녹음 → 전사 → 요약 · 기기 연결은 아래 링크" },
    { name: "Gmail", state: "next", note: "발송 · 회신 증거 자동 수집" },
    { name: "Google Calendar", state: "next", note: "수락 증거" },
    { name: "Slack", state: "next", note: "메시지 · 회신 증거" },
  ];
  return (
    <div className="app-panel">
      <h3>연결된 데이터 소스</h3>
      {rows.map((r) => (
        <div className="src-row" key={r.name}>
          <div>
            <div style={{ fontWeight: 700 }}>{r.name}</div>
            <div className="hint">{r.note}</div>
          </div>
          <span className={`pill ${r.state}`}>{r.state === "live" ? "Live" : r.state === "proto" ? "Prototype" : "Coming next"}</span>
        </div>
      ))}
      <p className="hint" style={{ marginTop: 12 }}>
        연결되지 않은 소스의 증거는 지금은 직접 붙여넣어 잠급니다. 자동 수집은 Coming next.{" "}
        <a href="/arca/onboarding?step=device&next=device" style={{ color: "var(--accent)" }}>
          Mac 앱 기기 연결 →
        </a>
      </p>
    </div>
  );
}

export function TastePanel({ taste }: { taste: Taste | null }) {
  const sum = (r: Record<string, number>) => Object.values(r).reduce((a, b) => a + b, 0);
  const consent = taste ? sum(taste.consent) : 0;
  const quality = taste ? sum(taste.quality) : 0;
  const max = Math.max(1, consent, quality);
  const list = (r: Record<string, number>) =>
    Object.entries(r).length === 0 ? <span className="mut">아직 없음</span> : Object.entries(r).map(([k, v]) => <span key={k}>{k} <b className="o">{v}</b></span>);
  return (
    <div className="app-panel">
      <h3>
        Taste Model <span className="pill proto" style={{ marginLeft: 8, fontSize: 10.5 }}>Prototype</span>
      </h3>
      <div className="rail consent">
        <div className="rl">
          <span>Consent · 맡길까</span>
          <span>{consent}</span>
        </div>
        <div className="bar">
          <i style={{ width: `${(consent / max) * 100}%` }} />
        </div>
        <div className="vals">{taste ? list(taste.consent) : <span className="mut">…</span>}</div>
      </div>
      <div className="rail quality">
        <div className="rl">
          <span>Quality · 좋았나</span>
          <span>{quality}</span>
        </div>
        <div className="bar">
          <i style={{ width: `${(quality / max) * 100}%` }} />
        </div>
        <div className="vals">{taste ? list(taste.quality) : <span className="mut">…</span>}</div>
      </div>
      <p className="hint" style={{ marginTop: 12 }}>
        두 레일은 따로 기록되고 한 점수로 섞지 않습니다. 지금은 기록만 하며, 다음 제안·질문 빈도에 반영하는 단계는 Coming next.
      </p>
    </div>
  );
}
