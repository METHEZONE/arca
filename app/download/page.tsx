import type { Metadata } from "next";
import "./download.css";

export const metadata: Metadata = {
  title: "Download ARCA — Mac, iPhone, Apple Watch",
  description:
    "Get the real ARCA build: the native macOS companion (direct download), the iOS + watchOS build on TestFlight, and the web dashboard.",
};

// Every button goes through the tracked hand-off (lib/arca/downloads.ts):
// one `downloads` row per click, then a redirect to the artifact itself.
const MAC_DMG = "/api/arca/download?t=mac-dmg&src=download-page";
const MAC_ZIP = "/api/arca/download?t=mac-zip&src=download-page";
const TESTFLIGHT = "/api/arca/download?t=ios-testflight&src=download-page";

export default function DownloadPage() {
  return (
    <main className="dl-root">
      <div className="dl-wrap">
        <p className="dl-kicker">ARCA · early build</p>
        <h1 className="dl-h1">Run the real thing.</h1>
        <p className="dl-lede">
          ARCA is a native companion, not a web demo. The Mac app below is the build I
          use every day: it wakes up in the notch, captures meetings from your mic and
          your system audio, files what it heard into memory, takes a delegation, and
          reports back when it&apos;s done. It is early, and it is real.
        </p>

        <video
          className="dl-video"
          src="/media/arca-demo.mp4"
          controls
          playsInline
          preload="metadata"
        />

        <section className="dl-card">
          <div className="dl-card-top">
            <h2>macOS companion</h2>
            <span className="dl-meta">Beta · Apple silicon · macOS 15+ · notarized DMG</span>
          </div>
          <p>
            The full companion: notch face, meeting detection, mic + system-audio
            capture, diarized transcripts, memory feed, screenshot to task or calendar
            event, and the &ldquo;arca it&rdquo; delegation loop with its own report.
          </p>
          <a className="dl-btn" href={MAC_DMG}>
            Download for Mac (.dmg)
          </a>
          <p className="dl-note">
            Open the DMG, drag ARCA into Applications, launch it. Developer ID signed and
            notarized, so no Gatekeeper dance. Prefer a plain zip?{" "}
            <a href={MAC_ZIP}>Download the .zip instead</a>. On first launch ARCA asks
            for microphone and screen recording (that is how it hears system audio); if you
            grant screen recording after the fact, quit and reopen once.
          </p>
          <p className="dl-note">
            Keys: the build ships with none of mine. Paste your own OpenAI and/or
            Anthropic key in Settings (stored in your Keychain only), or sign in to ARCA
            Cloud from <a href="/arca/onboarding">the onboarding page</a> and link the app
            with the code in Settings to run keyless on the shared beta budget.
          </p>
        </section>

        <section className="dl-card">
          <div className="dl-card-top">
            <h2>iPhone + Apple Watch</h2>
            <span className="dl-meta">TestFlight</span>
          </div>
          <p>
            The same engine on iOS, with the Watch app, widgets, Live Activity and the
            share extension. Record from your wrist, and it lands on your Mac.
          </p>
          <a className="dl-btn-ghost" href={TESTFLIGHT}>
            Join on TestFlight
          </a>
          <p className="dl-note">
            The public TestFlight link is live (Apple beta review cleared). Install
            TestFlight first if you don&apos;t have it. If it ever says the beta is full,
            email <a href="mailto:me@thezonebio.com">me@thezonebio.com</a> and I will add
            you to the tester group within minutes.
          </p>
        </section>

        <section className="dl-card">
          <div className="dl-card-top">
            <h2>Web dashboard</h2>
            <span className="dl-meta">nothing to install</span>
          </div>
          <p>
            Want to see the delegation loop without installing anything? Open the
            dashboard, press ⌘K and type <em>arca it — wrap up my latest meeting</em>.
            You will watch it recall, reason, draft, file and report in real time.
          </p>
          <a className="dl-btn-ghost" href="/">
            Open the web dashboard
          </a>
          <p className="dl-note">
            The web dashboard ships with seeded example memories so it is never empty on
            a first visit. The Mac app above is where the real capture happens.
          </p>
        </section>

        <h3 className="dl-h3">What works in this build</h3>
        <ul className="dl-list">
          <li>Meeting capture on macOS: microphone plus a Core Audio process tap for system audio</li>
          <li>Diarized transcripts, grounded summaries, decisions and an action plan</li>
          <li>Memory feed you can ask questions of in plain language</li>
          <li>Screenshot or share sheet to a task or a calendar event (EventKit)</li>
          <li>&ldquo;arca it&rdquo; delegation: recall → reason → draft → file → report back</li>
          <li>Connectors: Obsidian, Notion, Slack, Gmail</li>
          <li>Apple Watch capture, widgets and Live Activity / Dynamic Island</li>
          <li>Bring your own OpenAI / Anthropic keys, or sign in to ARCA Cloud and run keyless</li>
          <li>ARCA Cloud account (Google or email sign-in), device link, server-side memory across Mac / iPhone / Watch</li>
        </ul>

        <h3 className="dl-h3">Not there yet, honestly</h3>
        <ul className="dl-list">
          <li>A public App Store build (Mac is notarized DMG, iOS is TestFlight)</li>
          <li>Paid plans are not self-serve yet; picking one emails me</li>
          <li>HRV / sleep layer from the Watch and the ring (designed, not wired)</li>
          <li>ARCA Core, the carry-everywhere device with a face, is at printed prototype stage</li>
        </ul>

        <p className="dl-foot">
          Built by one person in Seoul. Questions, bugs, or you want in early:{" "}
          <a href="mailto:me@thezonebio.com">me@thezonebio.com</a> ·{" "}
          <a href="https://thezonebio.com/arca">thezonebio.com/arca</a> ·{" "}
          <a href="https://github.com/METHEZONE/arca/releases">release notes</a>
        </p>
      </div>
    </main>
  );
}
