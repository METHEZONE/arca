import type { Metadata } from "next";
import "./download.css";

export const metadata: Metadata = {
  title: "Download ARCA — Mac, iPhone, Apple Watch",
  description:
    "Get the real ARCA build: the native macOS companion (direct download), the iOS + watchOS build on TestFlight, and the web dashboard.",
};

const MAC_ZIP =
  "https://github.com/METHEZONE/arca/releases/download/mac-v1.0.1/ARCA-1.0-mac-arm64.zip";
const TESTFLIGHT = "https://testflight.apple.com/join/U78MNCxj";

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
            <span className="dl-meta">v1.0 · Apple silicon · 3.0 MB</span>
          </div>
          <p>
            The full companion: notch face, meeting detection, mic + system-audio
            capture, diarized transcripts, memory feed, screenshot to task or calendar
            event, and the &ldquo;arca it&rdquo; delegation loop with its own report.
          </p>
          <a className="dl-btn" href={MAC_ZIP}>
            Download for Mac
          </a>
          <p className="dl-note">
            Heads up, and I&apos;d rather say it here than surprise you: this build is
            signed with a development certificate and is not notarized yet, so macOS
            will warn you on first launch. Right-click the app, choose Open, then allow
            it once in System Settings → Privacy &amp; Security. Requires macOS 15+ on
            Apple silicon.
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
            The public TestFlight link opens as soon as Apple&apos;s beta review clears.
            If it says the beta is full or unavailable, email{" "}
            <a href="mailto:me@thezonebio.com">me@thezonebio.com</a> and I will add you
            to the tester group within minutes.
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
          <li>Runs with zero API keys in demo mode; add your own keys to go live</li>
        </ul>

        <h3 className="dl-h3">Not there yet, honestly</h3>
        <ul className="dl-list">
          <li>Notarized Mac release and a public App Store build</li>
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
