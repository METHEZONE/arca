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
    const qs = deviceToken ? `?device=${encodeURIComponent(deviceToken)}` : "";
    window.location.href = `${arcaBase()}/api/arca/auth/google${qs}`;
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
      <h1>Meet your second self.</h1>
      <p className="onb-sub">Sign in to get started — no password, no card.</p>

      {error && <p className="a-error">{error}</p>}

      {googleEnabled && (
        <button className="onb-google" onClick={onGoogle} type="button">
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
  const [activeNav, setActiveNav] = useState("Moments");
  const [inspectorTab, setInspectorTab] = useState<"scope" | "evidence">("scope");
  const [recording, setRecording] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);

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
        const wait = Math.max(0, 1400 - (Date.now() - started));
        setTimeout(() => {
          if (!cancelled) setPhase("reveal");
        }, wait);
      });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key.toLowerCase() === "r" && !event.metaKey && !event.ctrlKey) {
        const target = event.target as HTMLElement | null;
        if (target?.tagName === "INPUT" || target?.tagName === "TEXTAREA") return;
        setRecording((value) => !value);
      }
      if (event.key.toLowerCase() === "a" && !event.metaKey && !event.ctrlKey) {
        const target = event.target as HTMLElement | null;
        if (target?.tagName === "INPUT" || target?.tagName === "TEXTAREA") return;
        setAccepted(true);
      }
      if (event.key === "Escape") setSidebarOpen(false);
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  const c = moment?.commitment ?? null;
  const navItems = [
    { label: "Moments", icon: "✦", count: 1 },
    { label: "Commitments", icon: "✓", count: accepted ? 1 : 0 },
    { label: "Memory", icon: "◫" },
    { label: "People", icon: "◎" },
  ];

  return (
    <div className="arca-desktop-wrap">
      <div className="arca-desktop" aria-label="ARCA desktop workspace">
        <header className="arca-titlebar">
          <div className="arca-traffic" aria-hidden="true"><i /><i /><i /></div>
          <button className="arca-mobile-menu" type="button" onClick={() => setSidebarOpen((v) => !v)} aria-label="Toggle sidebar">☰</button>
          <div className="arca-window-title"><b>ARCA</b><span>Personal</span></div>
          <div className="arca-statusbar">
            <span className="arca-status"><i className="is-online" /> Synced now</span>
            <button className={recording ? "arca-record is-active" : "arca-record"} type="button" onClick={() => setRecording((v) => !v)} aria-pressed={recording} title="Toggle recording (R)">
              <i /> {recording ? "Recording" : "Record"}<kbd>R</kbd>
            </button>
            <span className="arca-agent-live"><i /> Agent online</span>
          </div>
        </header>

        <div className="arca-workspace">
          <aside className={sidebarOpen ? "arca-sidebar is-open" : "arca-sidebar"}>
            <div className="arca-profile">
              <span className="arca-avatar">MP</span>
              <div><strong>Minsung&apos;s ARCA</strong><small>Private workspace</small></div>
              <button type="button" aria-label="Workspace menu">···</button>
            </div>
            <nav aria-label="Workspace">
              <p>Workspace</p>
              {navItems.map((item) => (
                <button key={item.label} type="button" className={activeNav === item.label ? "is-active" : ""} onClick={() => { setActiveNav(item.label); setSidebarOpen(false); }}>
                  <span className="arca-nav-icon">{item.icon}</span>{item.label}
                  {item.count !== undefined && <em>{item.count}</em>}
                </button>
              ))}
            </nav>
            <div className="arca-sidebar-bottom">
              <p>Connected</p>
              <span><i className="is-online" /> MacBook Pro</span>
              <span><i /> Calendar</span>
              <button type="button">＋ Add source</button>
            </div>
          </aside>
          {sidebarOpen && <button className="arca-sidebar-scrim" type="button" aria-label="Close sidebar" onClick={() => setSidebarOpen(false)} />}

          <main className="arca-timeline">
            <div className="arca-pane-head">
              <div><span className="arca-eyebrow">Today · First contact</span><h1>{activeNav}</h1></div>
              <div className="arca-pane-actions"><button type="button" title="Search">⌕</button><button type="button" title="More">•••</button></div>
            </div>

            <div className="arca-feed">
              <div className="arca-day-rule"><span>Today</span></div>
              {phase === "reading" || !moment ? (
                <div className="arca-thinking">
                  <span className="arca-orb" aria-hidden="true"><i /></span>
                  <div><strong>ARCA is reading up on you</strong><p>No setup needed. I&apos;m checking public signals for something worth acting on.</p>
                    <div className="arca-scan"><span>Public writing</span><span>Upcoming events</span><span>Public profiles</span></div>
                  </div>
                </div>
              ) : (
                <>
                  <article className="arca-event">
                    <div className="arca-event-rail"><span className="arca-orb">A</span><i /></div>
                    <div className="arca-event-content">
                      <div className="arca-event-meta"><strong>ARCA</strong><span>just now</span><em>Proactive</em></div>
                      <div className="arca-message">{moment.message}</div>
                      <div className="arca-inline-sources">
                        <span>Found from</span>
                        {moment.sources.map((source) => <a key={source.url} href={source.url} target="_blank" rel="noreferrer">↗ {source.title}</a>)}
                      </div>
                    </div>
                  </article>

                  {c && (
                    <article className="arca-event arca-event-commitment">
                      <div className="arca-event-rail"><span className={accepted ? "arca-state-dot is-accepted" : "arca-state-dot"}>✓</span><i /></div>
                      <div className="arca-event-content">
                        <div className="arca-event-meta"><strong>Commitment detected</strong><span>now</span></div>
                        <section className={accepted ? "arca-commit-card is-accepted" : "arca-commit-card"}>
                          <div className="arca-commit-top">
                            <span>{accepted ? "Accepted" : "Proposed"}</span>
                            <small>{accepted ? "Work can begin in the scope below" : "Nothing runs until you say yes"}</small>
                          </div>
                          <h2>{c.title}</h2><p>{c.whyNow}</p>
                          <div className="arca-action-list">
                            {c.suggestedActions.map((action, index) => <div key={action}><span>{index + 1}</span><strong>{action}</strong><em>{accepted ? index === 0 ? "Queued" : "Watching" : "Ready"}</em></div>)}
                          </div>
                          {!accepted ? (
                            <div className="arca-commit-actions">
                              <button className="arca-primary" type="button" onClick={() => setAccepted(true)}>Hand it off <kbd>A</kbd></button>
                              <button type="button">Later</button>
                              <span>ARCA will report back with evidence.</span>
                            </div>
                          ) : (
                            <div className="arca-accepted-row"><span>✓ Scope accepted</span><button type="button" onClick={() => setAccepted(false)}>Review permission</button></div>
                          )}
                        </section>
                      </div>
                    </article>
                  )}
                </>
              )}
            </div>
            <footer className="arca-composer"><button type="button">＋</button><div><span>Ask ARCA or drop a commitment…</span><small>⌘ ↵ to send</small></div><button className="arca-voice" type="button" onClick={() => setRecording((v) => !v)}>{recording ? "■" : "◉"}</button></footer>
          </main>

          <aside className="arca-inspector">
            <div className="arca-inspector-head"><div><span>Inspector</span><strong>{c?.title ?? "First contact"}</strong></div><button type="button" aria-label="Close inspector">×</button></div>
            <div className="arca-inspector-tabs" role="tablist">
              <button type="button" role="tab" aria-selected={inspectorTab === "scope"} onClick={() => setInspectorTab("scope")}>Permission</button>
              <button type="button" role="tab" aria-selected={inspectorTab === "evidence"} onClick={() => setInspectorTab("evidence")}>Evidence</button>
            </div>
            {inspectorTab === "scope" ? (
              <div className="arca-inspector-body">
                <section><label>Lifecycle</label><div className="arca-lifecycle"><span className="is-done">Detected</span><span className="is-done">Proposed</span><span className={accepted ? "is-done" : ""}>Accepted</span><span>In progress</span><span>Verified</span></div></section>
                <section><label>Allowed now</label><div className="arca-permission"><span>Read public source</span><b>Allowed</b></div><div className="arca-permission"><span>Draft checklist</span><b>{accepted ? "Allowed" : "Needs approval"}</b></div><div className="arca-permission"><span>Change calendar</span><b>Ask every time</b></div></section>
                <section><label>Privacy</label><p>Conversation and memory stay off-chain. Only a minimal completion proof can be anchored.</p></section>
              </div>
            ) : (
              <div className="arca-inspector-body">
                <section><label>Source</label>{moment?.sources.map((source) => <a className="arca-evidence" key={source.url} href={source.url} target="_blank" rel="noreferrer"><span>Public writing</span><strong>{source.title}</strong><small>Open original ↗</small></a>)}</section>
                <section><label>Completion evidence</label><p>No evidence yet. ARCA will close this only when the calendar block or checklist can be verified.</p></section>
              </div>
            )}
            <div className="arca-inspector-foot"><span><i className="is-online" /> Local memory</span><small>Last sync: now</small></div>
          </aside>
        </div>
      </div>
      <button className="arca-demo-continue" type="button" onClick={onContinue}>Finish demo →</button>
    </div>
  );
}
