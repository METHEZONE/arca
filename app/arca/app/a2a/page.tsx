"use client";

import { useState } from "react";
import { motion } from "framer-motion";

const O = "#f75b2b";
const CREAM = "#fff3ea";
const MUT = "#6b625c";
const LINE = "#2a2320";

type Packet = { kind: "request" | "authority" | "evidence"; from: "me" | "them"; fields: string[]; withheld: string[] };

const STEPS: Array<{ title: string; note: string; packet?: Packet; myGate?: boolean; theirGate?: boolean; lock?: "both" }> = [
  {
    title: "내 ARCA가 공동 약속을 감지",
    note: "“다음 주에 김 대표님과 30분 미팅 잡을게요.” — 상대가 필요한 약속이므로 Shared lane이 열립니다.",
  },
  {
    title: "내 권한·조건을 먼저 확인",
    note: "내 ARCA는 내가 허락한 범위만 확인합니다: 다음 주 화·수 오후, 30분, 온라인. 그 밖의 판단은 나에게 묻습니다.",
    myGate: true,
  },
  {
    title: "request packet만 건너감",
    note: "원문 대화·내 캘린더 전체·개인 맥락은 건너가지 않습니다. 필요한 최소 필드만 표준 packet으로.",
    packet: { kind: "request", from: "me", fields: ["목적: 30분 미팅", "후보: 화·수 14–17시", "형식: 온라인"], withheld: ["회의 원문", "내 전체 캘린더", "다른 약속·취향"] },
  },
  {
    title: "상대 ARCA가 상대의 권한 안에서 응답",
    note: "상대 ARCA도 자기 사람의 승인 범위 안에서만 움직입니다. 가능한 시간 하나와 권한 범위를 authority packet으로 돌려줍니다.",
    theirGate: true,
    packet: { kind: "authority", from: "them", fields: ["가능: 수 15:00", "권한: 일정 확정까지", "조건: 링크는 상대가 발송"], withheld: ["상대 캘린더 전체", "상대 회사 내부 맥락"] },
  },
  {
    title: "양쪽 승인 범위 안에서 실행",
    note: "두 게이트가 모두 열렸으므로 각자 실행합니다: 내 ARCA는 초대 생성, 상대 ARCA는 회의 링크 발송. 사람은 한 문장만.",
    myGate: true,
    theirGate: true,
  },
  {
    title: "외부 증거로 양쪽 completion node lock",
    note: "캘린더 수락 + 링크 회신이라는 바깥 세상의 증거가 도착해야 두 사람의 완료 노드가 동시에 잠기고 공동 약속이 끝납니다.",
    packet: { kind: "evidence", from: "them", fields: ["캘린더 수락 · 수 15:00", "회의 링크 회신"], withheld: [] },
    lock: "both",
  },
];

export default function A2APage() {
  const [i, setI] = useState(0);
  const s = STEPS[i];
  const myOpen = STEPS.slice(0, i + 1).some((x) => x.myGate);
  const theirOpen = STEPS.slice(0, i + 1).some((x) => x.theirGate);
  const locked = s.lock === "both";

  const graph = (side: "me" | "them") => {
    const ox = side === "me" ? 40 : 620;
    const pts: Array<[number, number]> = [
      [ox + 40, 160], [ox + 130, 100], [ox + 130, 220], [ox + 220, 160], [ox + 300, 160],
    ];
    const active = side === "me" ? true : i >= 3;
    return (
      <g>
        <rect x={ox - 20} y={50} width={360} height={250} rx={18} fill="#0f0c0a" stroke={LINE} />
        <text x={ox} y={80} fill={MUT} fontSize={12} fontWeight={800} letterSpacing={1.4}>
          {side === "me" ? "MY ARCA · PRIVATE GRAPH" : "THEIR ARCA · PRIVATE GRAPH (PLACEHOLDER)"}
        </text>
        {[[0, 1], [0, 2], [1, 3], [2, 3], [3, 4]].map(([a, b], k) => (
          <line key={k} x1={pts[a][0]} y1={pts[a][1]} x2={pts[b][0]} y2={pts[b][1]} stroke={active && (k < 2 || i >= 4) ? O : "#3a302a"} strokeWidth={2} />
        ))}
        {pts.map(([x, y], k) => {
          const goal = k === 4;
          const lit = active && (k === 0 || (i >= 4 && k < 4) || (goal && locked));
          return (
            <g key={k}>
              {i >= 4 && !locked && k > 0 && k < 4 && active && (
                <motion.circle cx={x} cy={y} r={14} fill={O} animate={{ opacity: [0.35, 0, 0.35], scale: [1, 1.7, 1] }} transition={{ duration: 1.3, repeat: Infinity, delay: k * 0.25 }} style={{ transformOrigin: `${x}px ${y}px` }} />
              )}
              <circle cx={x} cy={y} r={goal ? 10 : 7} fill={lit ? O : "#171210"} stroke={active ? O : "#3a302a"} strokeWidth={1.6} />
              {goal && locked && (
                <motion.g initial={{ scale: 0.5, opacity: 0 }} animate={{ scale: 1, opacity: 1 }} style={{ transformOrigin: `${x}px ${y}px` }}>
                  <circle cx={x} cy={y} r={22} fill="none" stroke={O} strokeWidth={2} />
                  <rect x={x - 6} y={y - 1} width={12} height={9} rx={2} fill="#fff" />
                  <path d={`M${x - 3.5} ${y - 1} v-3 a3.5 3.5 0 0 1 7 0 v3`} fill="none" stroke="#fff" strokeWidth={1.8} />
                </motion.g>
              )}
            </g>
          );
        })}
        <text x={ox} y={282} fill={MUT} fontSize={12}>
          {side === "me" ? "원문 · 캘린더 전체 · 취향 = 여기 남음" : "실제 상대 사용자는 아직 없음 · 시뮬레이션"}
        </text>
      </g>
    );
  };

  return (
    <>
      <div className="app-head">
        <div>
          <h1>
            ARCA ↔ ARCA <span className="o">scoped coordination</span>
          </h1>
          <p>두 ARCA는 전체 맥락을 합치지 않습니다. request · authority · evidence packet만 오가고, 양쪽 게이트가 열려야 실행되고, 양쪽 완료 노드가 증거로 잠겨야 끝납니다.</p>
        </div>
        <span className="pill proto">Prototype — 시뮬레이션 · 상대 사용자 없음</span>
      </div>

      <div className="graph-wrap">
        <svg viewBox="0 0 1020 320">
          {graph("me")}
          {graph("them")}
          <defs>
            <linearGradient id="lane2" x1="0" x2="1">
              <stop offset="0" stopColor={O} stopOpacity={0} />
              <stop offset="0.5" stopColor={O} stopOpacity={0.14} />
              <stop offset="1" stopColor={O} stopOpacity={0} />
            </linearGradient>
          </defs>
          <rect x={380} y={50} width={240} height={250} fill="url(#lane2)" />
          <text x={500} y={76} textAnchor="middle" fill={O} fontSize={12} fontWeight={800} letterSpacing={1.4}>
            SCOPED PACKET LANE
          </text>
          <rect x={377} y={100} width={6} height={150} rx={3} fill={O} opacity={myOpen ? 0.95 : 0.25} />
          <rect x={617} y={100} width={6} height={150} rx={3} fill={O} opacity={theirOpen ? 0.95 : 0.25} />
          <text x={380} y={268} textAnchor="middle" fill={myOpen ? CREAM : MUT} fontSize={11} fontWeight={700}>
            내 게이트 {myOpen ? "열림" : "닫힘"}
          </text>
          <text x={620} y={268} textAnchor="middle" fill={theirOpen ? CREAM : MUT} fontSize={11} fontWeight={700}>
            상대 게이트 {theirOpen ? "열림" : "닫힘"}
          </text>
          {s.packet && (
            <motion.g
              key={i}
              initial={{ x: s.packet.from === "me" ? 386 : 614, opacity: 0 }}
              animate={{ x: s.packet.from === "me" ? 614 : 386, opacity: [0, 1, 1, 0.9] }}
              transition={{ duration: 1.4, ease: "easeInOut" }}
            >
              <rect x={-46} y={148} width={92} height={28} rx={7} fill="#120e0c" stroke={O} />
              <text x={0} y={167} textAnchor="middle" fill={O} fontSize={12} fontWeight={800}>
                {s.packet.kind}
              </text>
            </motion.g>
          )}
        </svg>
      </div>

      <div className="app-grid" style={{ marginTop: 28 }}>
        <div>
          <motion.div key={i} className="node-card" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}>
            <div className="nk">
              Step {i + 1} / {STEPS.length}
            </div>
            <h4>{s.title}</h4>
            <p className="q" style={{ color: "var(--sub)" }}>
              {s.note}
            </p>
            {s.packet && (
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
                <div>
                  <div className="nk">packet · 건너가는 필드</div>
                  <ul className="log" style={{ marginTop: 8 }}>
                    {s.packet.fields.map((f) => (
                      <li key={f}>{f}</li>
                    ))}
                  </ul>
                </div>
                <div>
                  <div className="nk" style={{ color: MUT }}>
                    비공개 · 건너가지 않음
                  </div>
                  <ul className="log" style={{ marginTop: 8 }}>
                    {s.packet.withheld.length === 0 ? <li>—</li> : s.packet.withheld.map((f) => <li key={f}>{f}</li>)}
                  </ul>
                </div>
              </div>
            )}
            <div className="row" style={{ marginTop: 18 }}>
              <button className="a-btn-ghost sm" onClick={() => setI(Math.max(0, i - 1))} disabled={i === 0}>
                ← 이전
              </button>
              <button className="a-btn sm" onClick={() => setI(Math.min(STEPS.length - 1, i + 1))} disabled={i === STEPS.length - 1}>
                다음 →
              </button>
              {i === STEPS.length - 1 && (
                <button className="chip" onClick={() => setI(0)}>
                  처음부터
                </button>
              )}
            </div>
          </motion.div>
        </div>
        <aside>
          <div className="app-panel">
            <h3>이 프로토타입의 경계</h3>
            <p className="hint">
              실제 두 번째 사용자·두 번째 ARCA 인스턴스는 아직 없습니다. 이 화면은 packet 최소화 · 양측 게이트 · 양측 증거 잠금이라는 제품 규칙을 시연하는 시뮬레이션입니다.
            </p>
            <p className="hint" style={{ marginTop: 10 }}>
              기술 근거: 캘린더 교집합 · 권한 게이트 · 증거 close는 데모 브랜치(METHEZONE/arca PR #6)에서만 동작하며 출시된 기능이 아닙니다.
            </p>
            <p className="hint" style={{ marginTop: 10 }}>ARCA does not replace human relationships. It removes the coordination tax around them.</p>
          </div>
        </aside>
      </div>
    </>
  );
}
