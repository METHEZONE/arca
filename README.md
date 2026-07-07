# ARCA — your independent second brain

ARCA turns recordings into **speaker-separated transcripts, structured
notes, and an executable action plan**, then automatically files each memory
into your second brain and pushes it to the connectors you control:
**Obsidian, Notion, and Slack**.

It runs as a polished web dashboard and as a hardware ingest target. Drop in a
recording, record in the browser, or let an ESP32-S3 recorder upload a WAV file.
ARCA then produces a color-coded transcript, grounded summary, decisions,
action items, and follow-up drafts.

And you can delegate: press **⌘K** and say **"arca it — wrap up my latest
meeting."** ARCA streams the whole loop live — recall the relevant memories,
reason over them, draft the recap and follow-ups, file the report back into
your second brain, and report completion.

> **Runs with zero keys.** ARCA works in demo mode out of the box, then activates
> each live layer as soon as its API key is present. A fresh install ships with
> four showcase memories so the feed (and delegation) is alive before your
> first recording; edit or delete them like any memory, or disable with
> `ARCA_SHOWCASE=off`.

---

## Quick start

```bash
npm install
npm run dev          # http://localhost:4174
```

Open the app, upload or record audio, and watch the pipeline run. To go live,
copy the env template and fill in what you have:

```bash
cp .env.local.example .env.local
```

| Capability | Env | Provider |
|---|---|---|
| Transcription + speakers | `OPENAI_API_KEY` and/or `ELEVENLABS_API_KEY` | OpenAI diarized STT first, ElevenLabs Scribe fallback |
| Notes & action plans | `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` | Claude / OpenAI |
| Obsidian sync | `OBSIDIAN_VAULT_PATH` | local/synced vault folder |
| Notion sync | `NOTION_API_KEY` + `NOTION_DATABASE_ID` | Notion API |
| Slack sync | `SLACK_WEBHOOK_URL` or `SLACK_BOT_TOKEN` + `SLACK_CHANNEL` | Slack |
| Hardware ingest token | `ARCA_INGEST_TOKEN` | optional shared secret |

`AUTO_PUSH_TARGETS=obsidian,notion,slack` controls which destinations receive a
memory automatically after each recording. It defaults to every configured
target; set `none` to disable.

---

## Hardware loop

ARCA is designed so today's recorder can stay simple:

```
button -> record WAV to microSD -> Wi-Fi multipart upload -> ARCA pipeline
```

The hardware endpoint is:

```http
POST /api/hardware/ingest
Content-Type: multipart/form-data
x-arca-device-token: <ARCA_INGEST_TOKEN, optional>
```

Multipart fields:

| Field | Required | Notes |
|---|---:|---|
| `recording` | yes | WAV, MP3, M4A, WebM, MP4, or raw octet stream up to 100MB |
| `deviceId` | no | Example: `arca-core-v0` |
| `battery` | no | Free-form voltage or percent |
| `recordedAt` | no | ISO timestamp if the device has time sync |

See [examples/esp32-s3-upload/arca_esp32_s3_upload.ino](examples/esp32-s3-upload/arca_esp32_s3_upload.ino)
for a minimal upload sketch. For local testing from a laptop:

```bash
curl -X POST http://localhost:4174/api/hardware/ingest \
  -H "x-arca-device-token: $ARCA_INGEST_TOKEN" \
  -F "recording=@arca_001.wav;type=audio/wav" \
  -F "deviceId=arca-core-v0"
```

If `ARCA_INGEST_TOKEN` is empty, the endpoint accepts local uploads without a
token. Set it before exposing ARCA through a tunnel, cloud host, or shared Wi-Fi.

---

## How it works

```
 recording ──▶ Ingest API ──▶ Transcribe (OpenAI diarized STT → ElevenLabs Scribe fallback)
                                      │
                                      ▼
                           Analyze (Claude/OpenAI)
                                      │
                                      ▼
                       Second brain (data/memories/*.json)
                                      │
                 ┌────────────────────┼────────────────────┐
                 ▼                    ▼                    ▼
              Obsidian              Notion                Slack
```

One shared ingest function drives browser uploads and hardware uploads. Every
stage degrades gracefully: a missing key falls back to demo output, and a failing
transcription provider still produces a saved memory with a clear warning, so a
recording is never silently lost.

### Architecture

```
app/
  page.tsx, components/        # dashboard, capture, feed, hardware bridge
  api/
    process-recording/         # browser ingest
    hardware/ingest/           # device ingest
    memories/[id]/             # second-brain read / update / delete
    integrations/              # on-demand push to Obsidian/Notion/Slack
    capabilities/              # what's wired vs demo
lib/
  ingest.ts                    # shared ingest pipeline
  types.ts                     # shared domain model
  config.ts                    # env reads + capability resolution
  transcription/                # OpenAI / ElevenLabs / demo transcription router
  analysis/                    # claude.ts · openai.ts · demo.ts · router
  secondbrain/store.ts         # local persistence
  integrations/                # obsidian.ts · notion.ts · slack.ts
  render.ts                    # markdown / Slack rendering
examples/
  esp32-s3-upload/             # hardware upload sketch
```

The second brain is plain JSON on disk (`data/`, gitignored). Memories carry the
full diarized transcript, the analysis, tags such as `hardware` and
`device:arca-core-v0`, and per-target sync status.

---

## Product workflow

ARCA follows the strongest pattern from dedicated AI recorders and meeting-note
connectors:

1. Capture must be instant and offline-tolerant.
2. Upload should be a simple append-only handoff from device to cloud/app.
3. Server-side processing owns transcription, speaker separation, summaries,
   decisions, and action items.
4. The result must land automatically in the user's actual knowledge surfaces,
   not stay trapped in the capture device.

That keeps today's hardware build focused on the alive loop while leaving room
for cloud hosting, background retries, charging-dock sync, and richer device
status later.

---

## API reference

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/capabilities` | What's configured vs demo |
| `POST` | `/api/process-recording` | Browser ingest, multipart field `recording` -> `Memory` |
| `POST` | `/api/hardware/ingest` | Hardware ingest, multipart field `recording` -> compact result |
| `GET` | `/api/memories` | The second-brain feed (`MemorySummary[]`) |
| `GET` | `/api/memories/{id}` | Full `Memory` |
| `PATCH` | `/api/memories/{id}` | Toggle an action item or set tags |
| `DELETE` | `/api/memories/{id}` | Delete a memory |
| `POST` | `/api/integrations` | Push `{memoryId, targets[]}` to Obsidian/Notion/Slack |
| `POST` | `/api/arca/delegate` | `{command}` -> SSE stream of delegation events, ending in a report |

The delegation loop reasons with Claude when `ANTHROPIC_API_KEY` is set and
degrades to grounded demo reasoning (built from the recalled memories' own
decisions and action plans) when it isn't — the loop always completes.
