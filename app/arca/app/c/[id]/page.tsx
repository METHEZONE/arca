"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { motion } from "framer-motion";

import { api, type Commitment, type Node, type Taste, NODE_KIND_KO, STATUS_KO } from "../../client";
import { TastePanel } from "../../panels";

const O = "#f75b2b";
const CREAM = "#fff3ea";
const MUT = "#6b625c";
const LINE = "#2a2320";
const W = 1000;
const H = 300;
const Y = 150;

type RunEvent = { position: number; status: string; note: string };

export default function CommitmentPage() {
  const { id } = useParams<{ id: string }>();
  const [c, setC] = useState<Commitment | null>(null);
  const [taste, setTaste] = useState<Taste | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [log, setLog] = useState<RunEvent[]>([]);
  const [drag, setDragState] = useState<{ from: number; to: number } | null>(null);
  // Ref mirrors the state so pointer handlers never read a stale closure
  // (a fast down→move→up can land before React re-renders).
  const dragRef = useRef<{ from: number; to: number } | null>(null);
  const setDrag = (d: { from: number; to: number } | null) => {
    dragRef.current = d;
    setDragState(d);
  };
  const svgRef = useRef<SVGSVGElement>(null);

  const load = useCallback(async () => {
    try {
      const [d, t] = await Promise.all([
        api<{ item: Commitment }>(`/api/arca/commitments/${id}`),
        api<{ taste: Taste }>("/api/arca/commitments"),
      ]);
      setC(d.item);
      setTaste(t.taste);
    } catch (e) {
      setError(e instanceof Error ? e.message : "불러오지 못했습니다.");
    }
  }, [id]);
  useEffect(() => {
    void load();
  }, [load]);

  const n = c?.nodes.length ?? 0;
  const xs = (i: number) => (n <= 1 ? W / 2 : 70 + (i * (W - 140)) / (n - 1));
  const ys = (i: number) => Y + (i % 2 === 0 ? 0 : i % 4 === 1 ? -34 : 34);

  const idxAt = (clientX: number) => {
    const svg = svgRef.current;
    if (!svg || n === 0) return 0;
    const r = svg.getBoundingClientRect();
    const x = ((clientX - r.left) / r.width) * W;
    let best = 0;
    for (let i = 0; i < n; i++) if (Math.abs(xs(i) - x) < Math.abs(xs(best) - x)) best = i;
    return best;
  };

  async function commitScope(from: number, to: number) {
    if (!c) return;
    const s = Math.min(from, to);
    const e = Math.max(from, to);
    if (s === e) return;
    try {
      const d = await api<{ item: Commitment }>(`/api/arca/commitments/${c.id}`, {
        method: "PATCH",
        body: JSON.stringify({ action: "scope", start: s, end: e }),
      });
      setC(d.item);
    } catch (err) {
      setError(err instanceof Error ? err.message : "범위 저장 실패");
    }
  }

  async function accept() {
    if (!c) return;
    setRunning(true);
    try {
      const d = await api<{ item: Commitment }>(`/api/arca/commitments/${c.id}`, { method: "PATCH", body: JSON.stringify({ action: "accept" }) });
      setC(d.item);
    } catch (e) {
      setError(e instanceof Error ? e.message : "실패했습니다.");
    } finally {
      setRunning(false);
    }
  }

  async function run() {
    if (!c) return;
    setRunning(true);
    setError(null);
    try {
      const d = await api<{ item: Commitment; events: RunEvent[] }>(`/api/arca/commitments/${c.id}/run`, { method: "POST" });
      setC(d.item);
      setLog((l) => [...d.events, ...l].slice(0, 12));
    } catch (e) {
      setError(e instanceof Error ? e.message : "실행 실패");
    } finally {
      setRunning(false);
    }
  }

  async function act(node: Node, body: Record<string, unknown>, thenRun = true) {
    if (!c) return;
    setRunning(true);
    setError(null);
    try {
      const d = await api<{ item: Commitment }>(`/api/arca/commitments/${c.id}/nodes/${node.id}`, { method: "POST", body: JSON.stringify(body) });
      setC(d.item);
      if (thenRun && d.item.status !== "verified") {
        const r = await api<{ item: Commitment; events: RunEvent[] }>(`/api/arca/commitments/${c.id}/run`, { method: "POST" });
        setC(r.item);
        setLog((l) => [...r.events, ...l].slice(0, 12));
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "실패했습니다.");
    } finally {
      setRunning(false);
    }
  }

  async function feedback(rail: "consent" | "quality", value: string, node?: Node) {
    if (!c) return;
    try {
      const d = await api<{ taste: Taste }>("/api/arca/feedback", {
        method: "POST",
        body: JSON.stringify({ commitmentId: c.id, nodeId: node?.id, rail, value }),
      });
      setTaste(d.taste);
    } catch (e) {
      setError(e instanceof Error ? e.message : "피드백 저장 실패");
    }
  }

  if (error && !c) {
    return (
      <div className="app-empty">
        <h2>불러오지 못했습니다</h2>
        <p>{error}</p>
        <Link className="a-btn-ghost" href="/arca/app">
          약속 목록
        </Link>
      </div>
    );
  }
  if (!c) return <div className="app-loading">Commitment Graph를 그리는 중</div>;

  const scoped = c.scopeStart !== null && c.scopeEnd !== null;
  const sel = drag ? { s: Math.min(drag.from, drag.to), e: Math.max(drag.from, drag.to) } : scoped ? { s: c.scopeStart!, e: c.scopeEnd! } : null;
  const gate = c.nodes.find((x) => x.status === "needs_approval" || x.status === "blocked" || x.status === "rejected") ?? null;
  const locked = c.nodes.filter((x) => x.status === "locked").length;
  const externalEvidence = c.nodes.filter((x) => x.status === "locked" && x.kind !== "start").length;

  return (
    <>
      <div className="app-head">
        <div>
          <Link href="/arca/app" className="mut" style={{ textDecoration: "none", fontSize: 14 }}>
            ← 약속 목록
          </Link>
          <h1 style={{ marginTop: 10 }}>{c.title}</h1>
          <p>
            {c.counterpart ? `${c.counterpart} · ` : ""}
            {c.due ?? "기한 미정"} · 결과: <span style={{ color: CREAM }}>{c.outcome}</span>
          </p>
        </div>
        <div className="row">
          <span className={`status ${c.status}`}>{STATUS_KO[c.status] ?? c.status}</span>
          <span className="pill live">Live · 그래프 · 초안</span>
          <span className="pill proto">Prototype · 외부 증거 수동</span>
        </div>
      </div>

      <div className="app-grid">
        <div>
          {(c.status === "detected" || c.status === "proposed") && (
            <motion.div className="node-card" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} style={{ marginBottom: 22, borderColor: "var(--accent)" }}>
              <div className="nk">Commitment detected</div>
              <h4>이 약속, ARCA가 맡을까요?</h4>
              <p className="q" style={{ color: "var(--ter)" }}>
                수락하면 Commitment Graph가 열립니다. 아무것도 실행되지 않습니다 — 범위를 드래그하기 전까지는.
              </p>
              <div className="row">
                <button className="a-btn" onClick={() => void accept()} disabled={running}>
                  ARCA it?
                </button>
                <Link className="chip" href="/arca/app">
                  나중에
                </Link>
              </div>
            </motion.div>
          )}
          <div className="graph-wrap">
            <svg
              ref={svgRef}
              viewBox={`0 0 ${W} ${H}`}
              onPointerMove={(e) => {
                const d = dragRef.current;
                if (d) setDrag({ ...d, to: idxAt(e.clientX) });
              }}
              onPointerUp={(e) => {
                const d = dragRef.current;
                if (d) {
                  void commitScope(d.from, idxAt(e.clientX));
                  setDrag(null);
                }
              }}
              onPointerLeave={() => {
                const d = dragRef.current;
                if (d) {
                  void commitScope(d.from, d.to);
                  setDrag(null);
                }
              }}
            >
              {/* scope region */}
              {sel && (
                <motion.g initial={false} animate={{ opacity: 1 }}>
                  <motion.rect
                    y={Y - 84}
                    height={168}
                    rx={20}
                    fill={O}
                    fillOpacity={0.12}
                    stroke={O}
                    strokeOpacity={0.7}
                    strokeDasharray="6 6"
                    initial={false}
                    animate={{ x: xs(sel.s) - 44, width: xs(sel.e) - xs(sel.s) + 88 }}
                    transition={{ duration: 0.35, ease: [0.22, 1, 0.36, 1] }}
                  />
                  <motion.text
                    y={Y - 96}
                    fill={O}
                    fontSize={12}
                    fontWeight={800}
                    letterSpacing={1.4}
                    initial={false}
                    animate={{ x: xs(sel.s) - 36 }}
                  >
                    이번 위임 범위 · {sel.e - sel.s + 1}단계
                  </motion.text>
                </motion.g>
              )}
              {/* edges */}
              {c.nodes.slice(0, -1).map((a, i) => {
                const b = c.nodes[i + 1];
                const lit = a.status === "locked" || a.status === "done";
                return (
                  <g key={a.id}>
                    <line x1={xs(i)} y1={ys(i)} x2={xs(i + 1)} y2={ys(i + 1)} stroke={LINE} strokeWidth={3} />
                    <motion.line
                      x1={xs(i)}
                      y1={ys(i)}
                      x2={xs(i + 1)}
                      y2={ys(i + 1)}
                      stroke={O}
                      strokeWidth={3}
                      initial={false}
                      animate={{ pathLength: lit ? 1 : 0, opacity: lit ? 1 : 0 }}
                      transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
                    />
                    {b.status === "pending" && sel && i + 1 >= sel.s && i + 1 <= sel.e && (
                      <line x1={xs(i)} y1={ys(i)} x2={xs(i + 1)} y2={ys(i + 1)} stroke={O} strokeOpacity={0.35} strokeWidth={3} strokeDasharray="4 6" />
                    )}
                  </g>
                );
              })}
              {/* nodes */}
              {c.nodes.map((node, i) => {
                const x = xs(i);
                const y = ys(i);
                const done = node.status === "locked" || node.status === "done";
                const halt = node.status === "needs_approval";
                const blocked = node.status === "blocked";
                const runningNode = node.status === "running" || (running && !done && !halt && i === (gate?.position ?? -1));
                const inScope = sel && i >= sel.s && i <= sel.e;
                return (
                  <g
                    key={node.id}
                    style={{ cursor: "grab" }}
                    onPointerDown={(e) => {
                      e.preventDefault();
                      setDrag({ from: i, to: i });
                    }}
                  >
                    {(runningNode || halt) && (
                      <motion.circle
                        cx={x}
                        cy={y}
                        r={18}
                        fill={halt ? CREAM : O}
                        animate={{ opacity: [0.3, 0, 0.3], scale: [1, 1.8, 1] }}
                        transition={{ duration: 1.4, repeat: Infinity }}
                        style={{ transformOrigin: `${x}px ${y}px` }}
                      />
                    )}
                    <rect
                      x={x - 24}
                      y={y - 24}
                      width={48}
                      height={48}
                      rx={11}
                      fill={done ? O : "#171210"}
                      stroke={halt ? CREAM : done || inScope ? O : blocked ? "#5a4a40" : "#3a302a"}
                      strokeWidth={halt ? 2.6 : 1.8}
                      strokeDasharray={blocked ? "4 4" : undefined}
                      transform={`rotate(45 ${x} ${y})`}
                    />
                    {node.status === "locked" && (
                      <g>
                        <rect x={x - 8} y={y - 2} width={16} height={11} rx={2} fill="#fff" />
                        <path d={`M${x - 5} ${y - 2} v-4 a5 5 0 0 1 10 0 v4`} fill="none" stroke="#fff" strokeWidth={2.2} />
                      </g>
                    )}
                    {node.status === "done" && (
                      <path d={`M${x - 8} ${y} l6 6 l11 -12`} fill="none" stroke="#fff" strokeWidth={3} strokeLinecap="round" />
                    )}
                    {halt && (
                      <text x={x} y={y + 7} textAnchor="middle" fill={CREAM} fontSize={22} fontWeight={900}>
                        ?
                      </text>
                    )}
                    {node.risky && !done && !halt && (
                      <text x={x} y={y + 5} textAnchor="middle" fill={O} fontSize={13} fontWeight={900}>
                        !
                      </text>
                    )}
                    <text x={x} y={y + 52} textAnchor="middle" fill={done ? CREAM : MUT} fontSize={13} fontWeight={700}>
                      {node.title}
                    </text>
                    <text x={x} y={y + 68} textAnchor="middle" fill={MUT} fontSize={10.5} fontWeight={700} letterSpacing={1.2}>
                      {(NODE_KIND_KO[node.kind] ?? node.kind).toUpperCase()}
                    </text>
                  </g>
                );
              })}
              {/* legend */}
              <text x={20} y={H - 14} fill={MUT} fontSize={11.5}>
                ◆ orange = 완료 · 🔒 = 외부 증거로 잠김 · ? = ARCA가 먼저 묻는 중 · ! = 경계 판단 · 점선 = 외부 연결 필요
              </text>
            </svg>
          </div>
          <div className="graph-help">
            <span>
              {scoped
                ? `범위: ${c.nodes[c.scopeStart!]?.title} → ${c.nodes[c.scopeEnd!]?.title} (노드를 다시 드래그하면 조정)`
                : "시작 노드에서 원하는 결과 노드까지 드래그하세요. 그만큼이 이번 위임 범위입니다."}
            </span>
            <span>
              잠긴 노드 {locked}/{n} · 외부 증거 {externalEvidence}
            </span>
          </div>

          <div className="row" style={{ marginTop: 22 }}>
            <button className="a-btn" onClick={() => void run()} disabled={running || !scoped || c.status === "verified"}>
              {running ? "ARCA 실행 중…" : c.status === "verified" ? "Verified · 닫힘" : scoped ? "범위 안 실행" : "먼저 범위를 드래그"}
            </button>
            {!scoped && <span className="hint">범위를 정하기 전에는 아무것도 실행하지 않습니다.</span>}
            {c.status === "verified" && <span className="pill live">Verified</span>}
          </div>

          {/* gate card */}
          {gate && (
            <GateCard
              key={gate.id + gate.status}
              node={gate}
              busy={running}
              onApprove={() => void act(gate, { type: "approve" })}
              onEdit={(artifact) => void act(gate, { type: "edit", artifact }, false)}
              onReject={() => void act(gate, { type: "reject" }, false)}
              onEvidence={(text, kind) => void act(gate, { type: "evidence", text, kind })}
              onFeedback={(rail, v) => void feedback(rail, v, gate)}
            />
          )}

          {c.status === "verified" && (
            <motion.div className="node-card" initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} style={{ marginTop: 22, borderColor: "var(--green)" }}>
              <div className="nk" style={{ color: "var(--green)" }}>
                Promise Packet · verified
              </div>
              <h4>“보냈어요”가 아니라 “끝났어요”.</h4>
              <p className="q" style={{ color: "var(--ter)" }}>
                목표 노드가 외부 증거로 잠겼습니다. 결과 품질은 어땠나요? (quality 레일에만 기록됩니다)
              </p>
              <div className="chips">
                <button className="chip o" onClick={() => void feedback("quality", "내 기준에 맞았다")}>
                  내 기준에 맞았다
                </button>
                <button className="chip" onClick={() => void feedback("quality", "수정 필요")}>
                  수정 필요
                </button>
              </div>
            </motion.div>
          )}

          {error && <p className="a-error" style={{ marginTop: 16 }}>{error}</p>}
          {log.length > 0 && (
            <ul className="log">
              {log.map((e, i) => (
                <li key={i}>
                  {e.position >= 0 ? `#${e.position + 1} ${c.nodes[e.position]?.title ?? ""} · ` : ""}
                  {e.note}
                </li>
              ))}
            </ul>
          )}

          {/* evidence trail */}
          {c.nodes.some((x) => x.evidence) && (
            <div className="app-panel" style={{ marginTop: 28 }}>
              <h3>Evidence trail</h3>
              {c.nodes
                .filter((x) => x.evidence)
                .map((x) => (
                  <div className="evidence" key={x.id}>
                    <b>
                      {x.title} · {x.evidenceKind}
                    </b>
                    <span>{x.evidence}</span>
                  </div>
                ))}
            </div>
          )}

          {c.sourceQuote && (
            <p className="hint" style={{ marginTop: 24 }}>
              출처 · “{c.sourceQuote}”{c.sourceSummary ? ` — ${c.sourceSummary}` : ""}
            </p>
          )}
        </div>

        <aside>
          <div className="app-panel">
            <h3>Promise Packet</h3>
            {["detected", "proposed", "accepted", "authorized", "in_progress", "evidence_submitted", "verified"].map((s) => {
              const order = ["detected", "proposed", "accepted", "authorized", "in_progress", "evidence_submitted", "verified"];
              const reached = order.indexOf(c.status) >= order.indexOf(s);
              return (
                <div className="src-row" key={s} style={{ padding: "7px 0" }}>
                  <span style={{ color: reached ? CREAM : MUT, fontWeight: reached ? 700 : 500 }}>{s}</span>
                  <span className={`status ${reached ? s : ""}`} style={{ fontSize: 10.5 }}>
                    {reached ? "●" : ""}
                  </span>
                </div>
              );
            })}
          </div>
          <TastePanel taste={taste} />
        </aside>
      </div>
    </>
  );
}

function GateCard({
  node,
  busy,
  onApprove,
  onEdit,
  onReject,
  onEvidence,
  onFeedback,
}: {
  node: Node;
  busy: boolean;
  onApprove: () => void;
  onEdit: (artifact: string) => void;
  onReject: () => void;
  onEvidence: (text: string, kind: string) => void;
  onFeedback: (rail: "consent" | "quality", value: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(node.artifact ?? "");
  const [ev, setEv] = useState("");
  const [kind, setKind] = useState("reply");
  const [consent, setConsent] = useState<string | null>(null);
  const [quality, setQuality] = useState<string | null>(null);
  const ask = node.status === "needs_approval";
  const blocked = node.status === "blocked";

  return (
    <motion.div className={`node-card ${ask ? "ask" : ""} ${blocked ? "blocked" : ""}`} initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} style={{ marginTop: 22 }}>
      <div className="nk">
        {ask ? "ARCA가 먼저 묻습니다" : blocked ? "외부 증거 필요" : "거절됨"} · #{node.position + 1} {NODE_KIND_KO[node.kind] ?? node.kind}
        {blocked && node.kind === "send" && (
          <span className="pill next" style={{ marginLeft: 10 }}>
            Gmail 발송 · Coming next
          </span>
        )}
      </div>
      <h4>{node.title}</h4>
      {node.question && <p className="q">{node.question}</p>}

      {node.artifact && (
        <>
          {editing ? (
            <textarea className="field" value={draft} onChange={(e) => setDraft(e.target.value)} style={{ marginBottom: 12 }} />
          ) : (
            <div className="artifact">{node.artifact}</div>
          )}
        </>
      )}

      {ask && (
        <div className="row">
          {editing ? (
            <>
              <button
                className="a-btn sm"
                disabled={busy}
                onClick={() => {
                  onEdit(draft);
                  setEditing(false);
                }}
              >
                수정 저장
              </button>
              <button className="chip" onClick={() => setEditing(false)}>
                취소
              </button>
            </>
          ) : (
            <>
              <button className="a-btn sm" disabled={busy} onClick={onApprove}>
                승인
              </button>
              {node.artifact && (
                <button className="a-btn-ghost sm" disabled={busy} onClick={() => setEditing(true)}>
                  수정
                </button>
              )}
              <button className="chip" disabled={busy} onClick={onReject}>
                거절
              </button>
            </>
          )}
        </div>
      )}

      {blocked && (
        <div style={{ display: "grid", gap: 10 }}>
          <div className="row">
            {["reply", "url", "calendar", "payment", "delivery", "other"].map((k) => (
              <button key={k} className={`chip ${kind === k ? "sel" : ""}`} onClick={() => setKind(k)}>
                {k === "reply" ? "상대 회신" : k === "url" ? "링크" : k === "calendar" ? "캘린더 수락" : k === "payment" ? "입금" : k === "delivery" ? "배송" : "기타"}
              </button>
            ))}
          </div>
          <textarea className="field" style={{ minHeight: 96 }} value={ev} onChange={(e) => setEv(e.target.value)} placeholder="바깥 세상의 증거를 붙여넣으세요 — 상대 회신 원문, 송장 번호, 캘린더 수락 메일, 입금 내역 등. ARCA의 자기 보고는 증거가 아닙니다." />
          <div className="row">
            <button className="a-btn sm" disabled={busy || ev.trim().length < 3} onClick={() => onEvidence(ev, kind)}>
              증거로 잠그기 🔒
            </button>
            <span className="hint">자동 수집(Gmail·Calendar·결제)은 Coming next. 지금은 직접 붙여넣기 = Prototype.</span>
          </div>
        </div>
      )}

      {node.status === "rejected" && <p className="hint">이 단계는 거절되었습니다. 초안을 수정하거나 범위를 다시 드래그해 주세요.</p>}

      <div style={{ marginTop: 20, borderTop: "1px solid var(--line)", paddingTop: 14 }}>
        <div className="rail consent" style={{ padding: "6px 0" }}>
          <div className="rl">
            <span>Consent 피드백 · 이런 단계는</span>
          </div>
          <div className="chips">
            {["맡길 것", "묻고 할 것", "하지 말 것"].map((v) => (
              <button
                key={v}
                className={`chip ${consent === v ? "sel" : ""}`}
                onClick={() => {
                  setConsent(v);
                  onFeedback("consent", v);
                }}
              >
                {v}
              </button>
            ))}
          </div>
        </div>
        {node.artifact && (
          <div className="rail quality" style={{ padding: "10px 0 0", borderTop: 0 }}>
            <div className="rl">
              <span>Quality 피드백 · 초안 품질은</span>
            </div>
            <div className="chips">
              {["내 기준에 맞았다", "수정 필요"].map((v) => (
                <button
                  key={v}
                  className={`chip ${quality === v ? "sel" : ""}`}
                  onClick={() => {
                    setQuality(v);
                    onFeedback("quality", v);
                  }}
                >
                  {v}
                </button>
              ))}
            </div>
          </div>
        )}
      </div>
    </motion.div>
  );
}
