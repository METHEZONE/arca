"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { Memory } from "@/lib/types";
import "./demo.css";

// ── State machine ────────────────────────────────────────────
type Phase = "idle" | "recording" | "processing" | "done" | "error";
type FaceExp = "sleep" | "listen" | "think" | "happy" | "sad";

const phaseToFace: Record<Phase, FaceExp> = {
  idle:       "sleep",
  recording:  "listen",
  processing: "think",
  done:       "happy",
  error:      "sad",
};

const phaseLabel: Record<Phase, string> = {
  idle:       "Tap to speak",
  recording:  "Listening...",
  processing: "Thinking...",
  done:       "Done",
  error:      "Something went wrong",
};

// ── ARCA Face ────────────────────────────────────────────────
function ArcaFace({ exp, bars }: { exp: FaceExp; bars: number[] }) {
  const [blink, setBlink] = useState(false);

  useEffect(() => {
    if (exp !== "sleep" && exp !== "happy") return;
    let t: ReturnType<typeof setTimeout>;
    function cycle() {
      t = setTimeout(() => {
        setBlink(true);
        setTimeout(() => { setBlink(false); cycle(); }, 120);
      }, 2400 + Math.random() * 2600);
    }
    cycle();
    return () => clearTimeout(t);
  }, [exp]);

  return (
    <div className={`face face--${exp}`}>
      <div className="face-body">
        {/* Eyes */}
        <div className="face-eyes">
          {exp === "sleep" && <>
            <div className="eye eye--sleep">—</div>
            <div className="eye eye--sleep">—</div>
          </>}
          {exp === "listen" && <>
            <div className="eye eye--open" style={{ height: blink ? 2 : undefined }} />
            <div className="eye eye--open" style={{ height: blink ? 2 : undefined }} />
          </>}
          {exp === "think" && <>
            <div className="eye eye--dot" />
            <div className="eye eye--dot" />
          </>}
          {exp === "happy" && <>
            <div className="eye eye--happy" style={{ height: blink ? 2 : undefined }} />
            <div className="eye eye--happy" style={{ height: blink ? 2 : undefined }} />
          </>}
          {exp === "sad" && <>
            <div className="eye eye--x">×</div>
            <div className="eye eye--x">×</div>
          </>}
        </div>

        {/* Mouth */}
        <div className="face-mouth">
          {exp === "sleep" && (
            <svg width="36" height="14" viewBox="0 0 36 14">
              <path d="M2 2 Q18 12 34 2" stroke="rgba(58,42,30,.55)" strokeWidth="2.5" strokeLinecap="round" fill="none"/>
            </svg>
          )}
          {exp === "listen" && (
            <div className="mouth-open" />
          )}
          {exp === "think" && (
            <div className="mouth-dots">
              <span/><span/><span/>
            </div>
          )}
          {exp === "happy" && (
            <svg width="44" height="18" viewBox="0 0 44 18">
              <path d="M2 2 Q22 18 42 2" stroke="rgba(58,42,30,.8)" strokeWidth="3" strokeLinecap="round" fill="none"/>
            </svg>
          )}
          {exp === "sad" && (
            <svg width="36" height="14" viewBox="0 0 36 14">
              <path d="M2 12 Q18 2 34 12" stroke="rgba(58,42,30,.55)" strokeWidth="2.5" strokeLinecap="round" fill="none"/>
            </svg>
          )}
        </div>
      </div>

      {/* Sound bars (recording state) */}
      {exp === "listen" && (
        <div className="face-bars">
          {bars.map((h, i) => (
            <div key={i} className="bar" style={{ height: `${h}%` }} />
          ))}
        </div>
      )}
    </div>
  );
}

// ── Timer display ─────────────────────────────────────────────
function useTimer(running: boolean) {
  const [sec, setSec] = useState(0);
  const ref = useRef<ReturnType<typeof setInterval> | undefined>(undefined);
  useEffect(() => {
    if (running) {
      setSec(0);
      ref.current = setInterval(() => setSec(s => s + 1), 1000);
    } else {
      clearInterval(ref.current);
    }
    return () => clearInterval(ref.current);
  }, [running]);
  return sec;
}

function fmtSec(s: number) {
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

// ── Sound level bars ──────────────────────────────────────────
function useSoundBars(stream: MediaStream | null) {
  const [bars, setBars] = useState<number[]>(Array(9).fill(12));
  const rafRef = useRef<number | undefined>(undefined);
  const analyserRef = useRef<AnalyserNode | undefined>(undefined);

  useEffect(() => {
    if (!stream) { setBars(Array(9).fill(12)); return; }
    const ctx = new AudioContext();
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 64;
    ctx.createMediaStreamSource(stream).connect(analyser);
    analyserRef.current = analyser;
    const data = new Uint8Array(analyser.frequencyBinCount);

    function tick() {
      analyser.getByteFrequencyData(data);
      const step = Math.floor(data.length / 9);
      setBars(Array.from({ length: 9 }, (_, i) => {
        const raw = data[i * step] / 255;
        return Math.max(8, Math.round(raw * 80));
      }));
      rafRef.current = requestAnimationFrame(tick);
    }
    tick();
    return () => {
      cancelAnimationFrame(rafRef.current!);
      ctx.close();
    };
  }, [stream]);

  return bars;
}

// ── Result display ────────────────────────────────────────────
function ResultPanel({ memory, onReset }: { memory: Memory; onReset: () => void }) {
  const a = memory.analysis;
  return (
    <div className="result-panel">
      <div className="result-title">{a.title}</div>
      <p className="result-summary">{a.summary}</p>

      {a.actionItems.length > 0 && (
        <section className="result-section">
          <div className="result-section-head">
            Action Items
            <span className="result-badge">{a.actionItems.length}</span>
          </div>
          <ul className="action-list">
            {a.actionItems.map(item => (
              <li key={item.id} className={`action-item action-item--${item.priority}`}>
                <span className="action-dot" />
                <div>
                  <div className="action-title">{item.title}</div>
                  <div className="action-meta">
                    {item.owner && <span>@{item.owner}</span>}
                    {item.due && <span>due {item.due}</span>}
                    <span className={`priority priority--${item.priority}`}>{item.priority}</span>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      {a.decisions.length > 0 && (
        <section className="result-section">
          <div className="result-section-head">Decisions</div>
          <ul className="bullet-list">
            {a.decisions.map((d, i) => (
              <li key={i}>{d.text}</li>
            ))}
          </ul>
        </section>
      )}

      {a.followups.length > 0 && (
        <section className="result-section">
          <div className="result-section-head">Follow-ups</div>
          <ul className="bullet-list">
            {a.followups.map((f, i) => <li key={i}>{f}</li>)}
          </ul>
        </section>
      )}

      {memory.transcript && (
        <section className="result-section result-section--muted">
          <div className="result-section-head">Transcript</div>
          <p className="transcript-text">{memory.transcript.fullText?.slice(0, 500)}{memory.transcript.fullText?.length > 500 ? "…" : ""}</p>
        </section>
      )}

      {memory.isDemo && (
        <div className="demo-notice">
          ⚠ Demo mode — add API keys to get real transcription &amp; analysis
        </div>
      )}

      <button className="btn-reset" onClick={onReset}>
        Try again ↺
      </button>
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────
export default function ArcaDemo() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [memory, setMemory] = useState<Memory | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [stream, setStream] = useState<MediaStream | null>(null);

  const recorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef   = useRef<Blob[]>([]);

  const bars  = useSoundBars(stream);
  const timer = useTimer(phase === "recording");
  const exp   = phaseToFace[phase];

  const mimeRef = useRef<string>("");

  const start = useCallback(async () => {
    if (phase !== "idle") return;
    setError(null); setMemory(null);
    try {
      const s = await navigator.mediaDevices.getUserMedia({ audio: true });
      setStream(s);
      chunksRef.current = [];
      // Pick the best supported MIME type (Safari needs mp4, Chrome prefers webm)
      const mime = ["audio/webm;codecs=opus","audio/webm","audio/mp4","audio/ogg"]
        .find(t => MediaRecorder.isTypeSupported(t)) ?? "";
      mimeRef.current = mime;
      const rec = mime ? new MediaRecorder(s, { mimeType: mime }) : new MediaRecorder(s);
      rec.ondataavailable = e => { if (e.data.size > 0) chunksRef.current.push(e.data); };
      rec.start(200);
      recorderRef.current = rec;
      setPhase("recording");
    } catch (e: any) {
      setError(e.message ?? "Microphone access denied");
    }
  }, [phase]);

  const stop = useCallback(async () => {
    if (phase !== "recording") return;
    setPhase("processing");
    const rec = recorderRef.current;
    if (!rec) return;
    setStream(null);

    rec.onstop = async () => {
      rec.stream.getTracks().forEach(t => t.stop());
      const mime = mimeRef.current || rec.mimeType || "audio/webm";
      const ext = mime.includes("mp4") ? "m4a" : mime.includes("ogg") ? "ogg" : "webm";
      const blob = new Blob(chunksRef.current, { type: mime });
      try {
        const fd = new FormData();
        fd.append("recording", blob, `recording.${ext}`);
        const res = await fetch("/api/process-recording", { method: "POST", body: fd });
        if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
        const data = await res.json() as Memory;
        setMemory(data);
        setPhase("done");
      } catch (e: any) {
        setError(e.message);
        setPhase("error");
      }
    };
    rec.stop();
  }, [phase]);

  const reset = useCallback(() => {
    setPhase("idle"); setMemory(null); setError(null);
  }, []);

  // tap = start if idle, stop if recording
  const onTap = phase === "idle" ? start : phase === "recording" ? stop : undefined;

  return (
    <div className="demo-root">
      <div className="demo-bg" />

      {/* Header */}
      <header className="demo-header">
        <a href="/" className="demo-logo">ARCA</a>
        <span className="demo-tag">Live Demo</span>
      </header>

      {/* Hero */}
      <main className="demo-main">
        <div className="demo-face-wrap">
          <button
            className={`face-btn ${onTap ? "face-btn--active" : ""}`}
            onClick={onTap}
            disabled={phase === "processing"}
            aria-label={phaseLabel[phase]}
          >
            <ArcaFace exp={exp} bars={bars} />
          </button>

          {phase === "recording" && (
            <div className="demo-timer">{fmtSec(timer)}</div>
          )}

          <div className={`demo-status demo-status--${phase}`}>
            {phase === "processing" ? (
              <span className="processing-dots">
                <span/><span/><span/>
              </span>
            ) : (
              phaseLabel[phase]
            )}
          </div>

          {phase === "recording" && (
            <button className="btn-stop" onClick={stop}>
              Stop &amp; Analyze
            </button>
          )}

          {error && (
            <div className="demo-error">
              {error}
              <button onClick={reset}>retry</button>
            </div>
          )}
        </div>

        {/* Results */}
        {phase === "done" && memory && (
          <ResultPanel memory={memory} onReset={reset} />
        )}

        {/* Idle instructions */}
        {phase === "idle" && (
          <div className="demo-hint">
            <div className="hint-step"><span>1</span> Tap the face to start recording</div>
            <div className="hint-step"><span>2</span> Speak — meeting notes, ideas, anything</div>
            <div className="hint-step"><span>3</span> ARCA transcribes &amp; builds your action plan</div>
          </div>
        )}
      </main>
    </div>
  );
}
