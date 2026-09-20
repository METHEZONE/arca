"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

import { api, type Commitment, type Taste, STATUS_KO } from "./client";
import { SourcesPanel, TastePanel } from "./panels";

export default function AppHome() {
  const [items, setItems] = useState<Commitment[] | null>(null);
  const [taste, setTaste] = useState<Taste | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    setError(null);
    try {
      const data = await api<{ items: Commitment[]; taste: Taste }>("/api/arca/commitments");
      setItems(data.items);
      setTaste(data.taste);
    } catch (e) {
      setError(e instanceof Error ? e.message : "불러오지 못했습니다.");
      setItems([]);
    }
  }
  useEffect(() => {
    void load();
  }, []);

  const open = items?.filter((c) => c.status !== "verified") ?? [];
  const done = items?.filter((c) => c.status === "verified") ?? [];

  return (
    <>
      <div className="app-head">
        <div>
          <h1>
            아직 닫히지 않은 <span className="o">약속</span>
          </h1>
          <p>무엇을 했는지가 아니라 무엇이 아직 닫히지 않았는지. 외부 증거로 잠긴 약속만 verified입니다.</p>
        </div>
        <Link className="a-btn" href="/arca/app/capture">
          + 대화 캡처
        </Link>
      </div>

      <div className="app-grid">
        <div>
          {items === null && !error && <div className="app-loading">약속을 불러오는 중</div>}
          {error && (
            <div className="app-empty">
              <h2>불러오지 못했습니다</h2>
              <p>{error}</p>
              <button className="a-btn-ghost" onClick={() => void load()}>
                다시 시도
              </button>
            </div>
          )}
          {items && items.length === 0 && !error && (
            <div className="app-empty">
              <h2>아직 감지된 약속이 없어요</h2>
              <p>회의를 녹음하거나 대화를 붙여넣으면 ARCA가 약속을 찾아 “ARCA it?” 하고 묻습니다.</p>
              <Link className="a-btn" href="/arca/app/capture">
                첫 대화 캡처하기
              </Link>
            </div>
          )}
          {open.length > 0 && (
            <div className="c-list">
              {open.map((c) => (
                <Card key={c.id} c={c} />
              ))}
            </div>
          )}
          {done.length > 0 && (
            <>
              <h3 className="mut" style={{ margin: "40px 0 14px", fontSize: 13, letterSpacing: "0.12em", textTransform: "uppercase" }}>
                Verified · 외부 증거로 닫힘
              </h3>
              <div className="c-list">
                {done.map((c) => (
                  <Card key={c.id} c={c} />
                ))}
              </div>
            </>
          )}
        </div>
        <aside>
          <SourcesPanel />
          <TastePanel taste={taste} />
        </aside>
      </div>
    </>
  );
}

function Card({ c }: { c: Commitment }) {
  const inScope = (p: number) => c.scopeStart !== null && c.scopeEnd !== null && p >= c.scopeStart && p <= c.scopeEnd;
  return (
    <Link className="c-card" href={`/arca/app/c/${c.id}`}>
      <div className="c-top">
        <span className={`status ${c.status}`}>{STATUS_KO[c.status] ?? c.status}</span>
        <span>
          {c.counterpart ? `${c.counterpart} · ` : ""}
          {c.due ?? "기한 미정"}
        </span>
      </div>
      <h4>{c.title}</h4>
      <div className="c-meta">→ {c.outcome}</div>
      <div className="c-mini" aria-hidden="true">
        {c.nodes.map((n, i) => (
          <span key={n.id} style={{ display: "contents" }}>
            {i > 0 && <b className={inScope(n.position) && inScope(n.position - 1) ? "in" : ""} />}
            <i className={n.status === "locked" || n.status === "done" ? "done" : n.status === "needs_approval" ? "halt" : inScope(n.position) ? "in" : ""} />
          </span>
        ))}
      </div>
    </Link>
  );
}
