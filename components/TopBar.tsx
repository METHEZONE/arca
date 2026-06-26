import type { JSX } from "react";
import type { Capabilities } from "@/lib/types";

export function TopBar({ caps }: { caps: Capabilities | null }): JSX.Element {
  return (
    <header className="topbar">
      <div className="wordmark">
        <span className="mark">
          ARC<em>A</em>
        </span>
        <span className="tag">second brain</span>
      </div>

      <div className="status-strip">
        {caps?.demoMode ? (
          <span
            className="demo-badge"
            title="Runs the full pipeline with demo data when API keys are missing."
          >
            Demo mode
          </span>
        ) : null}

        {caps
          ? caps.items.map((item) => (
              <span
                key={item.key}
                className={`cap-pill ${item.configured ? "live" : "muted"}`}
                title={item.detail}
              >
                <span className={`dot ${item.configured ? "on" : ""}`} />
                <span className="label">{item.label}</span>
                {item.configured && item.provider ? (
                  <span className="prov">{item.provider}</span>
                ) : null}
              </span>
            ))
          : Array.from({ length: 5 }).map((_, i) => (
              <span key={i} className="cap-pill muted">
                <span className="dot" />
                <span className="label">···</span>
              </span>
            ))}
      </div>
    </header>
  );
}
