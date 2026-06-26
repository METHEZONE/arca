"use client";

import { useEffect, useRef, useState, type JSX } from "react";
import type { Memory } from "@/lib/types";
import { formatBytes } from "./format";
import {
  IconUpload,
  IconMic,
  IconFile,
  IconClose,
  IconCheck,
  IconSpark,
} from "./icons";

const ACCEPT = ".mp3,.m4a,.wav,.webm,.mp4,.mpeg,.mpga";

const STAGES = [
  { key: "upload", label: "Upload", sub: "Uploading" },
  { key: "transcribe", label: "Transcript + speakers", sub: "Diarizing" },
  { key: "notes", label: "Generate notes", sub: "Generating notes" },
  { key: "save", label: "Save memory", sub: "Saving" },
  { key: "sync", label: "Sync connectors", sub: "Syncing" },
] as const;

type Props = {
  onProcessed: (memory: Memory) => void;
};

type ApiErrorPayload = {
  error?: string;
  detail?: string;
};

function isApiErrorPayload(value: unknown): value is ApiErrorPayload {
  return typeof value === "object" && value !== null && "error" in value;
}

async function readApiResponse(res: Response): Promise<unknown> {
  const text = await res.text();
  if (!text.trim()) return null;

  try {
    return JSON.parse(text) as unknown;
  } catch {
    if (!res.ok) return { error: text.slice(0, 220) || `HTTP ${res.status}` };
    throw new Error("ARCA could not read the server response. Please try again.");
  }
}

export function Capture({ onProcessed }: Props): JSX.Element {
  const [file, setFile] = useState<File | null>(null);
  const [dragging, setDragging] = useState(false);
  const [error, setError] = useState("");

  const [recording, setRecording] = useState(false);
  const [recSeconds, setRecSeconds] = useState(0);
  const [micDenied, setMicDenied] = useState(false);

  const [processing, setProcessing] = useState(false);
  const [stageIndex, setStageIndex] = useState(0);

  const recorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const recTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const stageTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    return () => {
      if (recTimerRef.current) clearInterval(recTimerRef.current);
      if (stageTimerRef.current) clearInterval(stageTimerRef.current);
      recorderRef.current?.stream.getTracks().forEach((t) => t.stop());
    };
  }, []);

  function pick(f: File | null) {
    setError("");
    setFile(f);
  }

  function onDrop(e: React.DragEvent) {
    e.preventDefault();
    setDragging(false);
    const f = e.dataTransfer.files?.[0];
    if (f) pick(f);
  }

  async function startRecording() {
    setError("");
    setMicDenied(false);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mr = new MediaRecorder(stream);
      chunksRef.current = [];
      mr.ondataavailable = (ev) => {
        if (ev.data.size > 0) chunksRef.current.push(ev.data);
      };
      mr.onstop = () => {
        const blob = new Blob(chunksRef.current, {
          type: mr.mimeType || "audio/webm",
        });
        const ext = (mr.mimeType || "audio/webm").includes("mp4") ? "mp4" : "webm";
        const recorded = new File([blob], `recording-${Date.now()}.${ext}`, {
          type: blob.type,
        });
        pick(recorded);
        stream.getTracks().forEach((t) => t.stop());
      };
      recorderRef.current = mr;
      mr.start();
      setRecording(true);
      setRecSeconds(0);
      recTimerRef.current = setInterval(() => setRecSeconds((s) => s + 1), 1000);
    } catch {
      setMicDenied(true);
    }
  }

  function stopRecording() {
    recorderRef.current?.stop();
    setRecording(false);
    if (recTimerRef.current) {
      clearInterval(recTimerRef.current);
      recTimerRef.current = null;
    }
  }

  async function process() {
    if (!file || processing) return;
    setError("");
    setProcessing(true);
    setStageIndex(0);

    // Animate intermediate stages while the single API call runs.
    stageTimerRef.current = setInterval(() => {
      setStageIndex((i) => (i < STAGES.length - 2 ? i + 1 : i));
    }, 1600);

    const body = new FormData();
    body.append("recording", file);

    try {
      const res = await fetch("/api/process-recording", {
        method: "POST",
        body,
      });
      const payload = await readApiResponse(res);
      if (!res.ok) {
        const message = isApiErrorPayload(payload)
          ? payload.error
          : `Processing failed. HTTP ${res.status}`;
        throw new Error(message ?? "Processing failed.");
      }
      if (!payload) {
        throw new Error("ARCA returned an empty response. Please try again.");
      }
      if (stageTimerRef.current) clearInterval(stageTimerRef.current);
      // Land on final stage briefly for a satisfying finish.
      setStageIndex(STAGES.length - 1);
      await new Promise((r) => setTimeout(r, 480));
      onProcessed(payload as Memory);
      setFile(null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Processing failed.");
    } finally {
      if (stageTimerRef.current) clearInterval(stageTimerRef.current);
      setProcessing(false);
      setStageIndex(0);
    }
  }

  const mm = Math.floor(recSeconds / 60)
    .toString()
    .padStart(2, "0");
  const ss = (recSeconds % 60).toString().padStart(2, "0");

  return (
    <aside className="panel capture">
      <div className="panel-head">
        <div>
          <div className="kicker">Capture</div>
          <h2>Add a memory</h2>
        </div>
      </div>

      {processing ? (
        <div className="process-area">
          <div className="stages">
            {STAGES.map((s, i) => {
              const state =
                i < stageIndex ? "done" : i === stageIndex ? "active" : "";
              return (
                <div key={s.key} className={`stage ${state}`}>
                  <div className="node">
                    {state === "done" ? (
                      <IconCheck size={13} />
                    ) : state === "active" ? (
                      <span className="spin" />
                    ) : (
                      <span style={{ fontSize: 10 }}>{i + 1}</span>
                    )}
                  </div>
                  <div>
                    <div className="txt">{s.label}</div>
                    <div className="sub">{s.sub}…</div>
                  </div>
                </div>
              );
            })}
          </div>
          <p className="dz-sub" style={{ textAlign: "center" }}>
            ARCA is turning this recording into a structured memory.
          </p>
        </div>
      ) : (
        <>
          {!file ? (
            <label
              className={`dropzone ${dragging ? "drag" : ""}`}
              onDragOver={(e) => {
                e.preventDefault();
                setDragging(true);
              }}
              onDragLeave={() => setDragging(false)}
              onDrop={onDrop}
            >
              <input
                type="file"
                accept={ACCEPT}
                onChange={(e) => pick(e.target.files?.[0] ?? null)}
              />
              <span className="dz-icon">
                <IconUpload size={22} />
              </span>
              <span className="dz-title">Drop a recording here</span>
              <span className="dz-sub">or click to choose a file</span>
              <span className="dz-formats">mp3 · m4a · wav · webm · mp4</span>
            </label>
          ) : (
            <div style={{ margin: "0 22px" }}>
              <div className="file-chip">
                <span className="fi">
                  <IconFile size={18} />
                </span>
                <span className="meta">
                  <span className="name">{file.name}</span>
                  <span className="size">{formatBytes(file.size)}</span>
                </span>
                <button
                  type="button"
                  className="clear"
                  aria-label="Remove file"
                  onClick={() => pick(null)}
                >
                  <IconClose size={16} />
                </button>
              </div>
            </div>
          )}

          {!file ? (
            <>
              <div className="divider-or">or</div>
              <div className="recorder">
                {recording ? (
                  <div className="rec-live" role="status" aria-live="polite">
                    <span className="rdot" />
                    <span className="timer">
                      {mm}:{ss}
                    </span>
                    <span className="wave" aria-hidden="true">
                      {Array.from({ length: 18 }).map((_, i) => (
                        <span
                          key={i}
                          style={{
                            animationDelay: `${(i % 9) * 0.08}s`,
                            animationDuration: `${0.7 + (i % 5) * 0.12}s`,
                          }}
                        />
                      ))}
                    </span>
                    <button type="button" className="rec-stop" onClick={stopRecording}>
                      Stop
                    </button>
                  </div>
                ) : (
                  <button type="button" className="rec-btn" onClick={startRecording}>
                    <span className="rdot" />
                    <IconMic size={17} /> Record now
                  </button>
                )}
              </div>
              {micDenied ? (
                <p className="permission-note">
                  Microphone access was blocked. Allow microphone permission in the browser, or
                  upload a file instead.
                </p>
              ) : null}
            </>
          ) : null}

          <div className="process-area">
            <button
              type="button"
              className="btn-primary"
              disabled={!file}
              onClick={process}
            >
              <IconSpark size={17} />
              {file ? "Process into memory" : "Add a recording first"}
            </button>
            {error ? <p className="form-error">{error}</p> : null}
          </div>
        </>
      )}
    </aside>
  );
}
