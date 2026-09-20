"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { motion } from "framer-motion";

import { api } from "../client";

type Source = { kind: "google" | "gravatar" | "domain" | "user"; label: string; url?: string; confidence: number };
type Candidate = {
  displayName: string | null;
  headline: string | null;
  company: string | null;
  companyUrl: string | null;
  avatarUrl: string | null;
  confidence: number;
  sources: Source[];
};
type Profile = Candidate & { confirmedAt: string | null };

const SCAN = ["Google 계정 (로그인 정보)", "Gravatar 공개 프로필", "이메일 도메인 공개 홈페이지"];

export default function IdentityOnboarding() {
  const [email, setEmail] = useState<string>("");
  const [phase, setPhase] = useState<"scan" | "ask" | "edit" | "done" | "error">("scan");
  const [scanStep, setScanStep] = useState(0);
  const [cand, setCand] = useState<Candidate | null>(null);
  const [existing, setExisting] = useState<Profile | null>(null);
  const [form, setForm] = useState({ displayName: "", headline: "", company: "" });
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    const t = setInterval(() => setScanStep((s) => Math.min(SCAN.length, s + 1)), 650);
    (async () => {
      try {
        const p = await api<{ email: string; profile: (Profile & { userId: string }) | null }>("/api/arca/profile");
        setEmail(p.email);
        if (p.profile?.confirmedAt) {
          setExisting(p.profile);
        }
        const c = await api<{ candidates: Candidate[] }>("/api/arca/identity/candidates");
        const first = c.candidates[0] ?? null;
        setCand(first);
        setForm({ displayName: first?.displayName ?? "", headline: first?.headline ?? "", company: first?.company ?? "" });
        setTimeout(() => setPhase("ask"), Math.max(0, SCAN.length * 650 + 300 - 900));
      } catch (e) {
        setError(e instanceof Error ? e.message : "확인에 실패했습니다.");
        setPhase("error");
      } finally {
        clearInterval(t);
        setScanStep(SCAN.length);
      }
    })();
    return () => clearInterval(t);
  }, []);

  async function confirm(useForm: boolean) {
    if (!cand) return;
    setSaving(true);
    setError(null);
    try {
      const body = useForm
        ? {
            displayName: form.displayName || null,
            headline: form.headline || null,
            company: form.company || null,
            companyUrl: cand.companyUrl,
            avatarUrl: cand.avatarUrl,
            sources: [...cand.sources, { kind: "user" as const, label: "사용자가 직접 확인·수정", confidence: 1 }],
          }
        : { ...cand, sources: [...cand.sources, { kind: "user" as const, label: "사용자가 “맞아요”로 확인", confidence: 1 }] };
      await api("/api/arca/profile", { method: "PUT", body: JSON.stringify(body) });
      setPhase("done");
    } catch (e) {
      setError(e instanceof Error ? e.message : "저장에 실패했습니다.");
    } finally {
      setSaving(false);
    }
  }

  async function remove() {
    setSaving(true);
    try {
      await api("/api/arca/profile", { method: "DELETE" });
      setExisting(null);
      setPhase("edit");
    } finally {
      setSaving(false);
    }
  }

  const high = (cand?.confidence ?? 0) >= 0.7;

  return (
    <div className="onb-wow">
      <p className="a-eyebrow">Onboarding · 30초</p>
      <motion.h1 className="lead" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.7 }}>
        Don&apos;t introduce yourself.
        <br />
        <span className="o">Let ARCA try.</span>
      </motion.h1>

      {phase === "scan" && (
        <ul className="onb-scan">
          {SCAN.map((s, i) => (
            <li key={s} className={i < scanStep ? "on" : ""}>
              <i />
              {s}
              {i < scanStep ? " · 확인" : ""}
            </li>
          ))}
          <li className="mut" style={{ marginTop: 6 }}>
            <i style={{ background: "transparent" }} />
            {email ? `${email} 하나로 공개 신호만 대조합니다. 비공개·민감 정보는 보지 않습니다.` : "…"}
          </li>
        </ul>
      )}

      {phase === "error" && (
        <div className="app-empty" style={{ marginTop: 36 }}>
          <h2>확인에 실패했어요</h2>
          <p>{error}</p>
          <button className="a-btn-ghost" onClick={() => location.reload()}>
            다시 시도
          </button>
        </div>
      )}

      {(phase === "ask" || phase === "edit") && cand && (
        <>
          {existing && phase === "ask" && (
            <p className="hint" style={{ marginTop: 28 }}>
              이미 확인된 프로필이 있어요 ({existing.displayName ?? email}). 아래에서 다시 확인하거나 삭제할 수 있습니다.{" "}
              <button className="chip" onClick={() => void remove()} disabled={saving} style={{ marginLeft: 8 }}>
                프로필 삭제
              </button>
            </p>
          )}
          <motion.div className="cand" initial={{ opacity: 0, y: 18 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.6 }}>
            {cand.avatarUrl ? <img src={cand.avatarUrl} alt="" referrerPolicy="no-referrer" /> : <div className="cand-ph" />}
            <div>
              <div className="conf">
                {high ? "혹시 이분이 맞나요?" : "확신이 낮아요 · 직접 알려주세요"}
                <b>
                  <i style={{ width: `${Math.round(cand.confidence * 100)}%` }} />
                </b>
                {Math.round(cand.confidence * 100)}%
              </div>
              {phase === "ask" ? (
                <>
                  <h2 style={{ marginTop: 10 }}>{cand.displayName ?? email.split("@")[0]}</h2>
                  <div className="cand-sub">
                    {[cand.company, cand.headline].filter(Boolean).join(" · ") || "공개 신호에서 회사·소개를 찾지 못했어요."}
                  </div>
                </>
              ) : (
                <div style={{ display: "grid", gap: 10, marginTop: 12 }}>
                  <input className="field" placeholder="이름" value={form.displayName} onChange={(e) => setForm({ ...form, displayName: e.target.value })} />
                  <input className="field" placeholder="회사 · 팀" value={form.company} onChange={(e) => setForm({ ...form, company: e.target.value })} />
                  <input className="field" placeholder="한 줄 소개 (역할)" value={form.headline} onChange={(e) => setForm({ ...form, headline: e.target.value })} />
                </div>
              )}
              <ul className="cand-src">
                {cand.sources.map((s, i) => (
                  <li key={i}>
                    출처 · {s.label}
                    {s.url ? (
                      <>
                        {" "}
                        <a href={s.url} target="_blank" rel="noreferrer">
                          보기 ↗
                        </a>
                      </>
                    ) : null}
                  </li>
                ))}
              </ul>
              {error && <p className="a-error" style={{ marginTop: 12 }}>{error}</p>}
              <div className="row" style={{ marginTop: 18 }}>
                {phase === "ask" ? (
                  <>
                    <button className="a-btn" onClick={() => void confirm(false)} disabled={saving || !cand.displayName}>
                      {saving ? "…" : "맞아요"}
                    </button>
                    <button className="a-btn-ghost" onClick={() => setPhase("edit")} disabled={saving}>
                      아니에요 · 직접 수정
                    </button>
                  </>
                ) : (
                  <>
                    <button className="a-btn" onClick={() => void confirm(true)} disabled={saving || !form.displayName}>
                      {saving ? "…" : "이 내용으로 확인"}
                    </button>
                    <button className="a-btn-ghost" onClick={() => setPhase("ask")} disabled={saving}>
                      돌아가기
                    </button>
                  </>
                )}
              </div>
            </div>
          </motion.div>
          <div className="guard">
            <div>
              <b>낮은 확신은 아는 척하지 않아요</b>70% 아래면 후보 대신 질문부터 합니다.
            </div>
            <div>
              <b>후보와 출처를 먼저 보여요</b>확인한 정보만 프로필에 들어가고, 후보는 저장되지 않습니다.
            </div>
            <div>
              <b>언제든 수정·삭제</b>비공개·민감 정보는 수집하지 않고, 다른 사람과 합치지 않습니다.
            </div>
          </div>
        </>
      )}

      {phase === "done" && (
        <motion.div initial={{ opacity: 0, y: 14 }} animate={{ opacity: 1, y: 0 }} style={{ marginTop: 40 }}>
          <div className="node-card" style={{ borderColor: "var(--accent)" }}>
            <div className="nk">ARCA · 첫 제안</div>
            <h4>
              {form.displayName || cand?.displayName || "반가워요"}
              {cand?.company || form.company ? `, ${form.company || cand?.company}의 약속부터 잡아볼게요.` : ", 첫 약속부터 잡아볼게요."}
            </h4>
            <p className="q">
              아직 놓친 약속을 아는 척하지 않습니다. 첫 회의를 녹음하거나 최근 대화를 붙여넣으면, 약속을 감지해 “ARCA it?” 하고 먼저 묻고, 범위를 드래그하면 그만큼만 움직입니다.
            </p>
            <div className="row">
              <Link className="a-btn" href="/arca/app/capture">
                첫 대화 캡처하기
              </Link>
              <Link className="a-btn-ghost" href="/arca/app">
                홈으로
              </Link>
            </div>
          </div>
        </motion.div>
      )}
    </div>
  );
}
