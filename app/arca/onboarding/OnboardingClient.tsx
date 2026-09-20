"use client";

import { useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

import { getDeviceToken } from "@/lib/arca/deviceClient";
import { arcaBase } from "@/lib/arca/origin";

type Step = "signin" | "sent" | "device" | "plan" | "moment" | "done";

const ERROR_COPY: Record<string, string> = {
  missing_token: "That link is missing its token — try requesting a new one.",
  invalid_link: "That link is invalid, expired, or already used — request a new one.",
  google_cancelled: "Google sign-in was cancelled.",
  google_state_expired: "That sign-in attempt expired — try again.",
  google_state_mismatch: "Something looked off with that sign-in attempt — try again.",
  google_exchange_failed: "Google sign-in failed — try again in a moment.",
};

const TIERS = [
  { name: "Companion", price: "$0", per: "forever", plan: "free" as const },
  { name: "Second Self", price: "$19", per: "/mo · founding price", plan: "pro" as const },
  { name: "ZONE for Teams", price: "$99", per: "/seat · /mo", plan: "team" as const },
];

export default function OnboardingClient({ googleEnabled }: { googleEnabled: boolean }) {
  const router = useRouter();
  const params = useSearchParams();
  const initialStep = (params.get("step") as Step | null) ?? "signin";

  const [step, setStep] = useState<Step>(
    initialStep === "device" ||
      initialStep === "plan" ||
      initialStep === "moment" ||
      initialStep === "done"
      ? initialStep
      : "signin",
  );
  const [error, setError] = useState<string | null>(
    params.get("error") ? ERROR_COPY[params.get("error")!] ?? "Something went wrong — try again." : null,
  );
  const [email, setEmail] = useState("");
  const [sending, setSending] = useState(false);
  const [me, setMe] = useState<{ email: string } | null>(null);
  const [meChecked, setMeChecked] = useState(false);

  // Clear the ?step=/?error= querystring once read, so a refresh doesn't
  // replay a stale error or re-fire the device-step session check.
  useEffect(() => {
    if (params.get("step") || params.get("error")) {
      router.replace("/arca/onboarding", { scroll: false });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (step !== "device") return;
    let cancelled = false;
    fetch(`${arcaBase()}/api/arca/me`, { credentials: "include" })
      .then((res) => (res.ok ? res.json() : null))
      .then((data) => {
        if (!cancelled) setMe(data);
      })
      .catch(() => {
        if (!cancelled) setMe(null);
      })
      .finally(() => {
        if (!cancelled) setMeChecked(true);
      });
    return () => {
      cancelled = true;
    };
  }, [step]);

  async function requestMagicLink(e: React.FormEvent) {
    e.preventDefault();
    if (!email.trim()) return;
    setSending(true);
    setError(null);
    try {
      const deviceToken = await getDeviceToken();
      const res = await fetch(`${arcaBase()}/api/arca/auth/request`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(deviceToken ? { "x-arca-device": deviceToken } : {}),
        },
        body: JSON.stringify({ email: email.trim() }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setError(data.error || "Couldn't send that link — try again.");
        setStep("signin");
        return;
      }
      if (data.devLink) {
        // No RESEND_API_KEY in this environment — jump straight there
        // instead of making a local dev loop wait on an email that will
        // never arrive.
        window.location.href = data.devLink as string;
        return;
      }
      setStep("sent");
    } catch {
      setError("Network error — try again.");
    } finally {
      setSending(false);
    }
  }

  async function continueWithGoogle() {
    setError(null);
    const deviceToken = await getDeviceToken();
    // Device-link flow only when the user explicitly came for it (Mac/iPhone
    // app hand-off); everyone else lands in the web app.
    const flow = params.get("next") === "device" || params.get("flow") === "device" ? "device" : "app";
    const q = new URLSearchParams({ flow });
    if (deviceToken) q.set("device", deviceToken);
    window.location.href = `${arcaBase()}/api/arca/auth/google?${q.toString()}`;
  }

  return (
    <div className="arca-root onb-root">
      <div className="onb-card">
        <a className="onb-logo" href="/arca">
          ARCA
        </a>

        {step === "signin" && (
          <SignIn
            email={email}
            setEmail={setEmail}
            sending={sending}
            error={error}
            googleEnabled={googleEnabled}
            onGoogle={continueWithGoogle}
            onSubmit={requestMagicLink}
          />
        )}

        {step === "sent" && (
          <div className="onb-step">
            <h1>Check your email</h1>
            <p className="onb-sub">
              We sent a sign-in link to <b>{email}</b>. Open it on this device to continue.
            </p>
            <button className="a-btn-ghost" onClick={() => setStep("signin")}>
              Use a different email
            </button>
          </div>
        )}

        {step === "device" && (
          <DeviceStep
            me={me}
            meChecked={meChecked}
            onContinue={() => setStep("plan")}
            onBackToSignIn={() => setStep("signin")}
          />
        )}

        {step === "plan" && <PlanStep onPick={() => setStep("moment")} />}

        {step === "moment" && <MomentStep onContinue={() => setStep("done")} />}

        {step === "done" && <DoneStep />}
      </div>
    </div>
  );
}

function SignIn({
  email,
  setEmail,
  sending,
  error,
  googleEnabled,
  onGoogle,
  onSubmit,
}: {
  email: string;
  setEmail: (v: string) => void;
  sending: boolean;
  error: string | null;
  googleEnabled: boolean;
  onGoogle: () => void;
  onSubmit: (e: React.FormEvent) => void;
}) {
  return (
    <div className="onb-step">
      <h1>약속을, 현실이 될 때까지.</h1>
      <p className="onb-sub">Google로 로그인하면 30초 안에 시작합니다. 비밀번호도, 카드도 없습니다. 원문은 당신의 계정에만 남습니다.</p>

      {error && <p className="a-error">{error}</p>}

      {googleEnabled && (
        <button className="onb-google" onClick={onGoogle} type="button">
          <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true"><path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.4 30.3 0 24 0 14.6 0 6.5 5.4 2.6 13.3l7.9 6.1C12.4 13.4 17.7 9.5 24 9.5z"/><path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.7c-.6 3-2.3 5.5-4.8 7.2l7.7 6c4.5-4.2 6.9-10.3 6.9-17.7z"/><path fill="#FBBC05" d="M10.5 28.6A14.5 14.5 0 0 1 9.5 24c0-1.6.3-3.1.8-4.6l-7.9-6.1A23.9 23.9 0 0 0 0 24c0 3.9.9 7.5 2.6 10.7l7.9-6.1z"/><path fill="#34A853" d="M24 48c6.3 0 11.7-2.1 15.6-5.7l-7.7-6c-2.1 1.4-4.8 2.3-7.9 2.3-6.3 0-11.6-4-13.5-9.9l-7.9 6.1C6.5 42.6 14.6 48 24 48z"/></svg>
          Continue with Google
        </button>
      )}

      <form className="onb-email" onSubmit={onSubmit}>
        <input
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@email.com"
          aria-label="Email address"
          type="email"
          inputMode="email"
          autoComplete="email"
          required
        />
        <button className="a-btn" type="submit" disabled={sending}>
          {sending ? "…" : "Continue with email"}
        </button>
      </form>
    </div>
  );
}

function DeviceStep({
  me,
  meChecked,
  onContinue,
  onBackToSignIn,
}: {
  me: { email: string } | null;
  meChecked: boolean;
  onContinue: () => void;
  onBackToSignIn: () => void;
}) {
  const [code, setCode] = useState("");
  const [linking, setLinking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [linked, setLinked] = useState(false);

  async function link(e: React.FormEvent) {
    e.preventDefault();
    if (!code.trim()) return;
    setLinking(true);
    setError(null);
    try {
      const res = await fetch(`${arcaBase()}/api/arca/device/link`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ deviceToken: code.trim() }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setError(data.error || "That code didn't work — check it and try again.");
        return;
      }
      setLinked(true);
    } catch {
      setError("Network error — try again.");
    } finally {
      setLinking(false);
    }
  }

  if (!meChecked) {
    return (
      <div className="onb-step">
        <p className="onb-sub">Loading…</p>
      </div>
    );
  }

  if (!me) {
    return (
      <div className="onb-step">
        <h1>We lost your session</h1>
        <p className="onb-sub">
          This link may have opened in a different browser than where you started. Sign in again to
          continue.
        </p>
        <button className="a-btn" onClick={onBackToSignIn}>
          Back to sign in
        </button>
      </div>
    );
  }

  return (
    <div className="onb-step">
      <h1>Connect your device</h1>
      <p className="onb-sub">
        Signed in as <b>{me.email}</b>. Open the ARCA app, find the device link code in Settings, and
        paste it here.
      </p>

      {error && <p className="a-error">{error}</p>}

      {linked ? (
        <p className="onb-ok">Device connected ✓</p>
      ) : (
        <form className="onb-email" onSubmit={link}>
          <input
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="Paste device link code"
            aria-label="Device link code"
            required
          />
          <button className="a-btn" type="submit" disabled={linking}>
            {linking ? "…" : "Link device"}
          </button>
        </form>
      )}

      <div className="onb-links">
        <a href="/download">Don&apos;t have the app yet? →</a>
        <button className="onb-skip" onClick={onContinue} type="button">
          {linked ? "Continue" : "I'll do this later"}
        </button>
      </div>
    </div>
  );
}

function PlanStep({ onPick }: { onPick: () => void }) {
  return (
    <div className="onb-step">
      <h1>Pick your plan</h1>
      <p className="onb-sub">Start free — no card required. Upgrade anytime.</p>
      <div className="onb-plans">
        {TIERS.map((t) =>
          t.plan === "free" ? (
            <button key={t.name} className="onb-plan onb-plan-hot" onClick={onPick} type="button">
              <h3>{t.name}</h3>
              <div className="a-price">
                {t.price}
                <small>{t.per}</small>
              </div>
              <span className="a-btn">Start free</span>
            </button>
          ) : (
            <a
              key={t.name}
              className="onb-plan"
              href={`mailto:me@thezonebio.com?subject=${encodeURIComponent(`ARCA — ${t.name} plan`)}`}
              onClick={onPick}
            >
              <h3>{t.name}</h3>
              <div className="a-price">
                {t.price}
                <small>{t.per}</small>
              </div>
              <span className="a-btn-ghost">Talk to us</span>
            </a>
          ),
        )}
      </div>
      <p className="onb-note">
        Paid plans aren&apos;t self-serve yet — picking one opens an email to get you set up by hand.
      </p>
    </div>
  );
}

function DoneStep() {
  return (
    <div className="onb-step onb-done">
      <h1>You&apos;re all set.</h1>
      <p className="onb-sub">Open ARCA and say &ldquo;arca it&rdquo; to try your first delegation.</p>
      {/* `arca://linked`, not a bare `arca://`: the app routes on the URL's
          host, so a scheme with nothing after it opens the app but tells it
          nothing. This host is what makes the app re-check its link status the
          moment the user comes back, instead of showing a stale 미연결 until
          settings are reopened. */}
      <a className="a-btn" href="arca://linked">
        Open ARCA
      </a>
      <a className="onb-skip-link" href="/download">
        Don&apos;t have the app installed? Download it →
      </a>
    </div>
  );
}


/* ---------------------------------------------------------------- *
 * First Contact — the moment ARCA speaks first (docs/ARCA-FIRST-CONTACT.md)
 * ---------------------------------------------------------------- */

type ClientCommitment = {
  state: "proposed";
  title: string;
  whyNow: string;
  suggestedActions: string[];
  evidence: string[];
};

type ClientMoment = {
  message: string;
  commitment: ClientCommitment | null;
  sources: Array<{ title: string; url: string }>;
  lang: "ko" | "en";
};

/** Offline/zero-identity fallback — the demo floor, same shape the API
 *  returns. A first hello that arrives beats one that waits on a session. */
function sampleMoment(lang: "ko" | "en"): ClientMoment {
  if (lang === "ko") {
    return {
      lang,
      message:
        "처음 뵙겠습니다. 연결 설정은 하지 않으셔도 괜찮아요. 공개된 글에서 「9월 서울 북토크」 소식을 봤습니다 (출처: https://ianpark.vc/p/instinct-10b).\n11일 남았습니다. 지금 제가 제안드릴 수 있는 건 \"9월 서울 북토크\" 준비입니다: 일정 블록 잡기, 준비 체크리스트 초안, 관련 후속 약속 감지하기. 맡기시겠어요? 동의하시기 전까지는 아무것도 실행하지 않습니다.",
      commitment: {
        state: "proposed",
        title: "9월 서울 북토크",
        whyNow: "11일 남았습니다.",
        suggestedActions: ["일정 블록 잡기", "준비 체크리스트 초안", "관련 후속 약속 감지하기"],
        evidence: ["https://ianpark.vc/p/instinct-10b"],
      },
      sources: [{ title: "이안의 주간 실리콘밸리", url: "https://ianpark.vc/p/instinct-10b" }],
    };
  }
  return {
    lang,
    message:
      "Hello. No setup needed — you don't have to connect anything. I saw \"September Seoul book talk\" in your public writing (source: https://ianpark.vc/p/instinct-10b).\n11 days out. What I can propose now is preparing for it: block the date, draft a prep checklist, watch for related follow-ups. Want me to take it? Nothing runs until you say yes.",
    commitment: {
      state: "proposed",
      title: "September Seoul book talk",
      whyNow: "11 days out.",
      suggestedActions: ["Block the date", "Draft a prep checklist", "Watch for related follow-ups"],
      evidence: ["https://ianpark.vc/p/instinct-10b"],
    },
    sources: [{ title: "Ian Park's newsletter", url: "https://ianpark.vc/p/instinct-10b" }],
  };
}

function MomentStep({ onContinue }: { onContinue: () => void }) {
  const [phase, setPhase] = useState<"reading" | "reveal">("reading");
  const [moment, setMoment] = useState<ClientMoment | null>(null);
  const [accepted, setAccepted] = useState(false);

  useEffect(() => {
    const lang: "ko" | "en" =
      typeof navigator !== "undefined" && navigator.language?.toLowerCase().startsWith("ko")
        ? "ko"
        : "en";
    let cancelled = false;
    const started = Date.now();

    fetch(`${arcaBase()}/api/arca/moments/first-contact`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ lang, signals: [] }),
    })
      .then((res) => (res.ok ? res.json() : null))
      .then((data) => {
        if (cancelled) return;
        setMoment(data?.moment ?? sampleMoment(lang));
      })
      .catch(() => {
        if (!cancelled) setMoment(sampleMoment(lang));
      })
      .finally(() => {
        if (cancelled) return;
        // Let the reading phase breathe even when the answer was instant —
        // the point of the scene is that ARCA went and looked.
        const wait = Math.max(0, 1800 - (Date.now() - started));
        setTimeout(() => {
          if (!cancelled) setPhase("reveal");
        }, wait);
      });

    return () => {
      cancelled = true;
    };
  }, []);

  if (phase === "reading" || !moment) {
    return (
      <div className="onb-step onb-moment-reading">
        <h1>ARCA is reading up on you.</h1>
        <p className="onb-sub">Nothing to connect. Nothing to set up.</p>
        <div className="onb-scan">
          <span className="onb-scan-line" style={{ animationDelay: "0s" }}>Public writing</span>
          <span className="onb-scan-line" style={{ animationDelay: "0.45s" }}>Upcoming events</span>
          <span className="onb-scan-line" style={{ animationDelay: "0.9s" }}>Public profiles</span>
        </div>
      </div>
    );
  }

  const c = moment.commitment;
  return (
    <div className="onb-step onb-moment">
      <div className="onb-chat">
        <span className="onb-agent-badge">ARCA · first contact</span>
        <div className="onb-bubble">{moment.message}</div>
        {moment.sources.length > 0 && (
          <div className="onb-sources">
            {moment.sources.map((s) => (
              <a key={s.url} className="onb-source" href={s.url} target="_blank" rel="noreferrer">
                {s.title}
              </a>
            ))}
          </div>
        )}
      </div>

      {c && (
        <div className="onb-commitment">
          <span className={accepted ? "onb-ptag onb-ptag-accepted" : "onb-ptag"}>
            {accepted
              ? "Accepted — ARCA works inside this scope and reports back with evidence"
              : "Proposed — nothing runs until you say yes"}
          </span>
          <h3>{c.title}</h3>
          <p className="onb-why">{c.whyNow}</p>
          <ul>
            {c.suggestedActions.map((a) => (
              <li key={a}>{a}</li>
            ))}
          </ul>
          {!accepted && (
            <div className="onb-cactions">
              <button className="a-btn" type="button" onClick={() => setAccepted(true)}>
                Hand it off
              </button>
              <button className="a-btn-ghost" type="button" onClick={() => setAccepted(false)}>
                Later
              </button>
            </div>
          )}
        </div>
      )}

      <button className="a-btn onb-moment-continue" type="button" onClick={onContinue}>
        Continue
      </button>
    </div>
  );
}
