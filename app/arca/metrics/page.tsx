"use client";

import { useEffect, useState } from "react";
import "../arca.css";

interface DayRow { day: string; proposals: number; approved: number; rejected: number; autoExecuted: number; approvalRate: number | null }
interface Metrics {
  since: string; until: string; users: number; installs: number; wau: number; closedLoops: number; meetings: number;
  byDay: DayRow[]; retention: { d1: number | null; d3: number | null; d7: number | null };
}

const pct = (v: number | null) => (v === null ? "—" : `${Math.round(v * 100)}%`);

function Line({ rows }: { rows: DayRow[] }) {
  const pts = rows.filter((r) => r.approvalRate !== null);
  if (pts.length === 0) return <p style={{ color: "var(--ter)" }}>승인/거절 데이터가 아직 없습니다.</p>;
  const w = 640, h = 180, pad = 24;
  const x = (i: number) => pad + (i * (w - 2 * pad)) / Math.max(1, pts.length - 1);
  const y = (v: number) => h - pad - v * (h - 2 * pad);
  const d = pts.map((r, i) => `${i === 0 ? "M" : "L"}${x(i)},${y(r.approvalRate as number)}`).join(" ");
  return (
    <svg viewBox={`0 0 ${w} ${h}`} width="100%" role="img" aria-label="위임 승인율 일별">
      <line x1={pad} y1={y(0)} x2={w - pad} y2={y(0)} stroke="var(--line)" />
      <line x1={pad} y1={y(1)} x2={w - pad} y2={y(1)} stroke="var(--line)" />
      <path d={d} fill="none" stroke="var(--accent)" strokeWidth={3} strokeLinecap="round" />
      {pts.map((r, i) => (
        <g key={r.day}>
          <circle cx={x(i)} cy={y(r.approvalRate as number)} r={4} fill="var(--accent)" />
          <text x={x(i)} y={h - 4} fontSize={10} textAnchor="middle" fill="var(--ter)">{r.day.slice(5)}</text>
        </g>
      ))}
    </svg>
  );
}

export default function MetricsPage() {
  const [token, setToken] = useState("");
  const [data, setData] = useState<Metrics | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => { setToken(localStorage.getItem("arcaMetricsToken") ?? ""); }, []);

  async function load() {
    setErr(null);
    localStorage.setItem("arcaMetricsToken", token);
    const res = await fetch("/api/brain/metrics", { headers: { "x-arca-token": token } });
    if (!res.ok) { setErr(`${res.status}`); setData(null); return; }
    setData((await res.json()) as Metrics);
  }

  useEffect(() => { if (token) void load(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [token]);

  return (
    <div className="arca-root" style={{ maxWidth: 900, margin: "0 auto", padding: 24 }}>
      <h1 style={{ fontSize: 24, fontWeight: 800 }}>ARCA 트랙션 <span style={{ color: "var(--ter)", fontWeight: 600 }}>live</span></h1>
      <div style={{ display: "flex", gap: 8, margin: "12px 0" }}>
        <input value={token} onChange={(e) => setToken(e.target.value)} placeholder="invite code" style={{ flex: 1, padding: 10, borderRadius: 12, border: "1px solid var(--line)" }} />
        <button onClick={load} style={{ padding: "10px 16px", borderRadius: 12, background: "var(--accent)", color: "#fff", border: 0, fontWeight: 700 }}>새로고침</button>
      </div>
      {err && <p style={{ color: "var(--accent)" }}>오류 {err}</p>}
      {data && (
        <>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(4,1fr)", gap: 12 }}>
            {[["사용자", data.users], ["주간 활성", data.wau], ["닫힌 루프", data.closedLoops], ["회의", data.meetings]].map(([k, v]) => (
              <div key={k as string} style={{ background: "var(--field)", borderRadius: 16, padding: 16 }}>
                <div style={{ fontSize: 32, fontWeight: 800 }}>{v as number}</div>
                <div style={{ color: "var(--ter)", fontSize: 13 }}>{k as string}</div>
              </div>
            ))}
          </div>
          <p style={{ color: "var(--sub)", margin: "12px 0" }}>리텐션 D1 {pct(data.retention.d1)} · D3 {pct(data.retention.d3)} · D7 {pct(data.retention.d7)} · 기준 {data.since.slice(0, 10)}</p>
          <h2 style={{ fontSize: 16, fontWeight: 700, margin: "18px 0 8px" }}>위임 승인율 · 일별</h2>
          <Line rows={data.byDay} />
        </>
      )}
    </div>
  );
}
