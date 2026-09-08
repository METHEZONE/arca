"use client";

import { useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

import { getDeviceToken } from "@/lib/arca/deviceClient";
import { arcaBase } from "@/lib/arca/origin";

type Step = "signin" | "sent" | "device" | "plan" | "done";

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
    initialStep === "device" || initialStep === "plan" || initialStep === "done"
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

        {step === "plan" && <PlanStep onPick={() => setStep("done")} />}

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
