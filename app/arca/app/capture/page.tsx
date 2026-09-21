"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { motion } from "framer-motion";

import { api, type Commitment } from "../client";

const SAMPLE = `민성: 네, 그럼 김 대표님께 금요일까지 견적서 보내드릴게요. 수량은 300개 기준으로요.
김대표: 좋아요. 단가는 조금 조정 여지 있죠?
민성: 5% 안에서는 제가 판단할 수 있고, 그 이상은 내부 확인이 필요합니다.
김대표: 그리고 지난번 말한 샘플 3종도 같이 보내주시면 좋겠어요.
민성: 샘플은 다음 주 화요일에 택배로 보내드리겠습니다. 송장 번호도 공유드릴게요.`;

export default function Capture() {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState<"idle" | "transcribing" | "extracting">("idle");
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ summary: string; provider: string; items: Commitment[] } | null>(null);
  const [rec, setRec] = useState<"off" | "on">("off");
  const [secs, setSecs] = useState(0);
  const recRef = useRef<MediaRecorder | null>(null);
  const chunks = useRef<Blob[]>([]);
  const timer = useRef<number | null>(null);
  const [accepting, setAccepting] = useState<string | null>(null);

  useEffect(() => () => { if (timer.current) clearInterval(timer.current); }, []);

  async function startRec() {
    setError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mr = new MediaRecorder(stream, { mimeType: MediaRecorder.isTypeSupported("audio/webm") ? "audio/webm" : "audio/mp4" });
      chunks.current = [];
      mr.ondataavailable = (e) => e.data.size > 0 && chunks.current.push(e.data);
      mr.onstop = async () => {
        stream.getTracks().forEach((t) => t.stop());
        const blob = new Blob(chunks.current, { type: mr.mimeType });
        await transcribe(blob);
      };
      mr.start(1000);
      recRef.current = mr;
      setRec("on");
      setSecs(0);
      timer.current = window.setInterval(() => setSecs((s) => s + 1), 1000);
    } catch {
      setError("마이크 권한이 필요합니다. 대신 대화를 붙여넣어도 됩니다.");
    }
  }
  function stopRec() {
    recRef.current?.stop();
    setRec("off");
    if (timer.current) clearInterval(timer.current);
  }
  async function transcribe(blob: Blob) {
    setBusy("transcribing");
    try {
      const fd = new FormData();
      fd.append("file", blob, `capture.${blob.type.includes("mp4") ? "m4a" : "webm"}`);
      fd.append("language", "ko");
      const data = await api<{ text?: string; transcript?: string }>("/api/arca/transcribe", { method: "POST", body: fd });
      const t = data.text ?? data.transcript ?? "";
      if (!t) throw new Error("전사 결과가 비어 있습니다.");
      setText((prev) => (prev ? `${prev}\n${t}` : t));
    } catch (e) {
      setError(e instanceof Error ? e.message : "전사에 실패했습니다.");
    } finally {
      setBusy("idle");
    }
  }

  async function extract() {
    setError(null);
    setBusy("extracting");
    setResult(null);
    try {
      const data = await api<{ summary: string; provider: string; items: Commitment[] }>("/api/arca/commitments/extract", {
        method: "POST",
        body: JSON.stringify({ text, kind: "text" }),
      });
      setResult(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "약속 추출에 실패했습니다.");
    } finally {
      setBusy("idle");
    }
  }

  async function arcaIt(id: string) {
    setAccepting(id);
    try {
      await api(`/api/arca/commitments/${id}`, { method: "PATCH", body: JSON.stringify({ action: "accept" }) });
      window.location.assign(`/arca/app/c/${id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "실패했습니다.");
      setAccepting(null);
    }
  }
  async function later(id: string) {
    await api(`/api/arca/commitments/${id}`, { method: "DELETE" }).catch(() => null);
    setResult((r) => (r ? { ...r, items: r.items.filter((c) => c.id !== id) } : r));
  }

  return (
    <>
      <div className="app-head">
        <div>
          <h1>
            대화를 <span className="o">캡처</span>하세요
          </h1>
          <p>녹음하거나 붙여넣으면 ARCA가 약속을 감지하고 하나씩 “ARCA it?” 하고 묻습니다. 회의 원문은 계정에만 저장됩니다.</p>
        </div>
        <div className="row">
          <span className="pill live">Live · 전사 + 약속 감지</span>
        </div>
      </div>

      <div className="app-grid">
        <div>
          <div className="row" style={{ marginBottom: 12 }}>
            {rec === "off" ? (
              <button className="a-btn-ghost sm" onClick={() => void startRec()} disabled={busy !== "idle"}>
                ● 브라우저에서 녹음
              </button>
            ) : (
              <button className="a-btn sm" onClick={stopRec}>
                ■ 녹음 중지 · {Math.floor(secs / 60)}:{String(secs % 60).padStart(2, "0")}
              </button>
            )}
            <button className="chip" onClick={() => setText(SAMPLE)} disabled={busy !== "idle"}>
              샘플 대화 넣기
            </button>
            <span className="hint">{busy === "transcribing" ? "전사 중… (whisper)" : "또는 아래에 회의록·채팅을 붙여넣기"}</span>
          </div>
          <textarea className="field" value={text} onChange={(e) => setText(e.target.value)} placeholder="여기에 대화를 붙여넣으세요. 20자 이상." />
          {error && <p className="a-error" style={{ marginTop: 12 }}>{error}</p>}
          <div className="row" style={{ marginTop: 14 }}>
            <button className="a-btn" onClick={() => void extract()} disabled={busy !== "idle" || text.trim().length < 20}>
              {busy === "extracting" ? "약속 감지 중…" : "약속 감지하기"}
            </button>
            <span className="hint">감지 → “ARCA it?” → 범위 드래그 → 실행</span>
          </div>

          {busy === "extracting" && <div className="app-loading">대화에서 약속을 찾고 경로를 그리는 중</div>}

          {result && (
            <motion.div initial={{ opacity: 0, y: 14 }} animate={{ opacity: 1, y: 0 }} style={{ marginTop: 32 }}>
              <div className="app-panel">
                <h3>요약 · {result.provider === "demo" ? <span className="pill next">Demo 추출 (모델 키 없음)</span> : <span className="pill live">{result.provider}</span>}</h3>
                <p style={{ margin: 0, color: "var(--sub)", lineHeight: 1.55 }}>{result.summary}</p>
              </div>
              {result.items.length === 0 && (
                <div className="app-empty" style={{ marginTop: 20 }}>
                  <h2>약속을 찾지 못했어요</h2>
                  <p>“~까지 ~할게요” 같은 실제 약속이 있는 대화를 넣어 주세요. 없는 약속은 만들지 않습니다.</p>
                </div>
              )}
              <div className="c-list" style={{ marginTop: 20 }}>
                {result.items.map((c, i) => (
                  <motion.div key={c.id} className="node-card" initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: i * 0.12 }}>
                    <div className="nk">Commitment detected · {c.due ?? "기한 미정"}</div>
                    <h4>{c.title}</h4>
                    <p className="q" style={{ color: "var(--ter)", fontSize: 15 }}>
                      {c.counterpart ? `${c.counterpart}에게 · ` : ""}결과: {c.outcome}
                      {c.sourceQuote ? (
                        <>
                          <br />
                          <span className="mut">“{c.sourceQuote}”</span>
                        </>
                      ) : null}
                    </p>
                    <div className="c-mini" style={{ marginBottom: 16 }}>
                      {c.nodes.map((n, k) => (
                        <span key={n.id} style={{ display: "contents" }}>
                          {k > 0 && <b />}
                          <i title={n.title} />
                        </span>
                      ))}
                      <span className="hint" style={{ marginLeft: 8 }}>
                        {c.nodes.map((n) => n.title).join(" → ")}
                      </span>
                    </div>
                    <div className="row">
                      <button className="a-btn" onClick={() => void arcaIt(c.id)} disabled={accepting !== null}>
                        {accepting === c.id ? "…" : "ARCA it?"}
                      </button>
                      <button className="chip" onClick={() => void later(c.id)} disabled={accepting !== null}>
                        나중에 · 삭제
                      </button>
                    </div>
                  </motion.div>
                ))}
              </div>
            </motion.div>
          )}
        </div>
        <aside>
          <div className="app-panel">
            <h3>어떻게 감지하나</h3>
            <p className="hint">
              말한 사람이 실제로 한 약속만 찾습니다(“~까지 ~할게요”). 각 약속은 시작 → 결과까지의 경로로 그려지고, 돈·가격·제3자 관련 단계는 경계 질문으로 표시됩니다. 없는 사람·금액·날짜는 만들지 않습니다.
            </p>
            <p className="hint" style={{ marginTop: 10 }}>
              녹음은 브라우저에서 바로 서버 전사(whisper)로 보내지고 오디오는 저장하지 않습니다.
            </p>
            <Link className="a-btn-ghost sm" href="/arca/app" style={{ marginTop: 14 }}>
              ← 약속 목록
            </Link>
          </div>
        </aside>
      </div>
    </>
  );
}
