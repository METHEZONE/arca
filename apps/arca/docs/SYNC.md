# ARCA cross-device sync — design decision (2026-07-04)

Goal: Mac ↔ iPhone ↔ Watch share one brain — sessions/notes, todos, chat log,
and long-term memory (`MemoryFact`). Audio stays device-local (too big; the
transcript is the durable artifact).

## Options considered

| Option | Verdict |
|---|---|
| **CloudKit (SwiftData mirroring)** | The clean rail — zero server, same-Apple-ID magic. **Blocked today**: the iCloud capability needs a *paid* Apple Developer membership; current signing is a free personal team (membership tangle with the IRLU org is being resolved with Apple Support). Revisit the moment enrollment lands. |
| Google login + own backend | Real auth infra to build & run; overkill for a single-user personal tool right now. |
| Obsidian/iCloud Drive file vault | iCloud Drive also needs the iCloud entitlement; Obsidian vault is Mac-centric. |
| **GitHub private repo (chosen v1)** | Each device pushes/pulls JSON+Markdown snapshots via the GitHub contents API with a PAT stored in Keychain (staged from `~/.arca` on Mac, pasted once on iPhone). Zero new infra, durable, versioned, and the repo doubles as an Obsidian-openable markdown brain. Watch syncs through the phone (WCSession, already built). |

## v1 shape (next session)

- Repo: `arca-brain` (private). Layout: `sessions/<uuid>.md` (frontmatter +
  transcript + notes), `tasks.json`, `memory.json`, `chatlog/<month>.json`.
- Client: `GitHubSyncBackend: SyncBackend` in `Store` (contents API, ETag
  last-write-wins per file; conflicts resolved by newest `updatedAt`).
- Triggers: push on session save / task change / chat end; pull on app
  foreground + every 10 min on Mac.
- Settings: "Sync" section — PAT field, repo name, sync toggle, last-sync line.

## Migration path

When paid membership lands, add CloudKit mirroring for SwiftData models and
retire the GitHub backend (or keep it as the export/brain format — it's nice).
