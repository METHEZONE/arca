import type { JSX } from "react";
import { IconUpload, IconCheck } from "./icons";

const STEPS = [
  "ESP32-S3 records WAV audio",
  "Wi-Fi upload uses multipart ingest",
  "ARCA generates transcripts, notes, and actions",
  "Connectors sync to Obsidian, Notion, and Slack",
];

export function HardwareBridge(): JSX.Element {
  return (
    <section className="hardware-band" aria-labelledby="hardware-title">
      <div>
        <p className="eyebrow">Hardware bridge</p>
        <h2 id="hardware-title">The recorder uploads straight into ARCA.</h2>
        <p>
          The device only has to capture and send audio. The ARCA server owns transcription,
          analysis, memory storage, and connector syncs.
        </p>
      </div>

      <div className="endpoint-card">
        <div className="endpoint-icon">
          <IconUpload size={20} />
        </div>
        <div className="endpoint-main">
          <span className="endpoint-label">Device upload endpoint</span>
          <code>POST /api/hardware/ingest</code>
          <span className="endpoint-sub">
            multipart field: <code>recording</code> · optional: <code>deviceId</code>,{" "}
            <code>battery</code>, <code>recordedAt</code>
          </span>
        </div>
      </div>

      <div className="hardware-steps">
        {STEPS.map((step) => (
          <span key={step}>
            <IconCheck size={13} />
            {step}
          </span>
        ))}
      </div>
    </section>
  );
}
