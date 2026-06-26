import type { JSX } from "react";
import type { Transcript as TranscriptType } from "@/lib/types";
import { formatClock, formatDuration, speakerColor } from "./format";

export function Transcript({ transcript }: { transcript: TranscriptType }): JSX.Element {
  // Stable speaker -> index mapping (drives consistent colors + chat side).
  const order = new Map<string, number>();
  transcript.speakers.forEach((s, i) => order.set(s.speaker, i));
  transcript.segments.forEach((seg) => {
    if (!order.has(seg.speaker)) order.set(seg.speaker, order.size);
  });

  const totalTalk = transcript.speakers.reduce((sum, s) => sum + s.talkTimeSec, 0) || 1;

  return (
    <div>
      <div className="talktime">
        {transcript.speakers.map((s) => {
          const idx = order.get(s.speaker) ?? 0;
          const c = speakerColor(idx);
          const pct = Math.round((s.talkTimeSec / totalTalk) * 100);
          return (
            <div className="tt-row" key={s.speaker}>
              <span className="tt-name" style={{ color: c.ink }}>
                <span className="tt-swatch" style={{ background: c.ink }} />
                {s.speakerLabel}
              </span>
              <span className="tt-bar">
                <span
                  className="tt-fill"
                  style={{ width: `${pct}%`, background: c.ink }}
                />
              </span>
              <span className="tt-val">
                {formatDuration(s.talkTimeSec)} · {pct}%
              </span>
            </div>
          );
        })}
      </div>

      <div className="transcript">
        {transcript.segments.map((seg, i) => {
          const idx = order.get(seg.speaker) ?? 0;
          const c = speakerColor(idx);
          const side = idx % 2 === 0 ? "left" : "right";
          return (
            <div
              key={`${seg.speaker}-${seg.startMs}-${i}`}
              className={`seg ${side}`}
              style={{
                background: c.soft,
                border: `1px solid ${c.line}`,
                animationDelay: `${Math.min(i, 18) * 0.02}s`,
              }}
            >
              <div className="seg-head">
                <span className="seg-name" style={{ color: c.ink }}>
                  {seg.speakerLabel}
                </span>
                <span className="seg-time">{formatClock(seg.startMs)}</span>
              </div>
              <div className="seg-text">{seg.text}</div>
            </div>
          );
        })}
      </div>

      {transcript.warning ? (
        <div className="warn-banner">
          <span>⚠</span>
          <span>{transcript.warning}</span>
        </div>
      ) : null}
    </div>
  );
}
