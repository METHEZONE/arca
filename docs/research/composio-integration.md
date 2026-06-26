# Composio Integration Spec — ARCA Connector Layer (native macOS Swift)

---

## ✅ LIVE-VERIFIED (2026-06-25, real project API key, `https://backend.composio.dev/api/v3`)

Every fact below was confirmed with `curl` against the live v3 API. Where it differs from the older notes further down, **trust this section.**

### API-key-only onboarding (no hand-copied auth_config_ids)
A fresh project has **zero** auth configs. ARCA creates one per toolkit on demand using Composio-managed auth — no Google/Slack OAuth-app registration, no dashboard step.

1. **List existing** (server-side filter works):
   `GET /auth_configs?toolkit_slug=GMAIL` → `{ "items": [ { "id": "ac_…", "is_composio_managed": true, "toolkit": { "slug": "gmail" }, … } ], "total_items": N }`. Empty project → `items: []`.
2. **Create managed auth config** (the keystone — body confirmed):
   ```
   POST /auth_configs
   { "toolkit": { "slug": "GMAIL" },
     "auth_config": { "type": "use_composio_managed_auth" } }
   → 201 { "toolkit": { "slug": "gmail" },
           "auth_config": { "id": "ac_PbBPfcevTrWu", "auth_scheme": "OAUTH2", "is_composio_managed": true } }
   ```
   Same body shape works for SLACK (`ac_e2Y6Js-k57dt`) and (by the toolkit metadata) the other managed-OAUTH2 toolkits. `GET /toolkits/GMAIL` reports `"composio_managed_auth_schemes": ["OAUTH2"]`, confirming zero-setup managed auth is available.
3. **Initiate connection** — response shape DIFFERS from the older notes:
   ```
   POST /connected_accounts/link
   { "user_id": "arca-...", "auth_config_id": "ac_…" }
   → 201 { "link_token": "lk_…",
           "redirect_url": "https://connect.composio.dev/link/lk_…",   ← open this
           "connected_account_id": "ca_…",                              ← store/poll this
           "expires_at": "...", "experimental": { "account_type": "PRIVATE" } }
   ```
   **No `id` and no `status` field here** — the account id is `connected_account_id`, the consent URL is `redirect_url` (resolves 200 to the hosted `platform.composio.dev/link/…` consent page).
4. **Poll** (unchanged endpoint):
   `GET /connected_accounts/{ca_id}` → `{ "id": "ca_…", "status": "INITIALIZING", "toolkit": { "slug": "gmail" }, "auth_config": { "id": "ac_…", "is_composio_managed": true }, … }`. Poll top-level `status` until `ACTIVE`. (Consent not completed during probe, so only `INITIALIZING` observed — but the status field, account, and consent URL are all real.)

### Execute — `user_id` is REQUIRED alongside `connected_account_id`
The older note's body (`connected_account_id` + `arguments` only) **fails**:
```
POST /tools/execute/GMAIL_FETCH_EMAILS
{ "connected_account_id":"ca_…", "arguments": {...} }
→ 400 code 1811 ActionExecute_ConnectedAccountEntityIdRequired
   "User ID is required with connected account."
```
Correct body (verified — 422 only because the probe account wasn't ACTIVE yet, which proves the shape is otherwise accepted):
```
{ "connected_account_id":"ca_…", "user_id":"arca-…", "arguments": {...} }
```
Success response shape: `{ "data": {…}, "error": null, "successful": true }`.

### Verified tool arg schemas (`GET /tools/{SLUG}`)
- **GMAIL_FETCH_EMAILS** — no required args. Useful: `max_results` (int), `query` (string, Gmail search), `include_payload`, `verbose`, `label_ids`, `page_token`.
- **GMAIL_SEND_EMAIL** — **required: `recipient_email`, `body`**. Plus `subject`, `is_html` (bool), `cc`/`bcc` (array), `extra_recipients`, `attachment` (object).
- **SLACK_FETCH_CONVERSATION_HISTORY** — **required: `channel`** (id or name). Plus `limit` (1–1000), `cursor`, `oldest`, `latest`, `inclusive`.
- **SLACK_SEND_MESSAGE** — **required: `channel`**. Body field: **`markdown_text` is PREFERRED**; `text`/`blocks` are marked DEPRECATED. Plus `thread_ts`, `as_user`, etc.

### Cleanup endpoints (used to leave the project pristine after probing)
`DELETE /connected_accounts/{ca_id}` → `{ "success": true }`; `DELETE /auth_configs/{ac_id}` → `{ "success": true }`. Project left with 0 auth configs.

### What the user must still do
Just **click Connect → approve in the browser**. No dashboard work, no auth_config_id copying. ARCA auto-creates the managed auth config from the API key, opens the consent page, and polls to ACTIVE.

---

> Goal: integrate **Composio** (composio.dev) as the managed-OAuth connector layer for ARCA, a pure-Swift SwiftPM executable. No Node/Python runtime; everything is HTTP via `URLSession`. We replicate the **HeyClicky flow**: user clicks "Connect" → Composio hosts the OAuth consent ("Secured by Composio", `backend.composio.dev`) → ARCA polls until ACTIVE → ARCA executes tool actions (Gmail, Slack, Notion, Google Calendar, GitHub).
>
> Researched against live docs (docs.composio.dev) as of **2026-06**. Current API is **v3 / v3.1** (the `composio`/`@composio/core` SDK generation). The old `v1.docs.composio.dev` line is **legacy** — do not use it.

---

## 0. TL;DR (the keystone facts)

- **Base URL:** `https://backend.composio.dev/api/v3` (some newer routes are `…/api/v3.1`; both live under `backend.composio.dev`).
- **Auth header:** `x-api-key: <COMPOSIO_API_KEY>` (project key). Org-level routes use `x-org-api-key`. Always also send `Content-Type: application/json`.
- **Connect flow (REST):**
  1. `POST /api/v3/connected_accounts/link` (preferred, hosted) — body `{ user_id, auth_config_id, callback_url? }` → returns `{ id, redirect_url, status }`.
  2. Open `redirect_url` with `NSWorkspace.shared.open` → Composio hosts the consent screen + callback. **You do not host a callback.**
  3. Poll `GET /api/v3/connected_accounts/{id}` until `status == "ACTIVE"`.
- **Execute:** `POST /api/v3/tools/execute/{TOOL_SLUG}` — body `{ "connected_account_id": "ca_…", "arguments": { … } }` → returns `{ data, error, successful }`.
- **User must set up:** Composio account → API key (from `dashboard.composio.dev/settings`) → one **auth config** per toolkit (GMAIL, SLACK, NOTION, GOOGLECALENDAR, GITHUB) on the dashboard, each yielding an `auth_config_id` (`ac_…`). For a demo, use **Composio-managed auth** (zero OAuth-app registration).

---

## 1. Account / dashboard setup (what the developer does once)

Sources: [Connected Accounts](https://docs.composio.dev/docs/auth-configuration/connected-accounts), [Authenticating Tools](https://docs.composio.dev/docs/authenticating-tools), [Managed vs custom auth](https://docs.composio.dev/docs/custom-app-vs-managed-app), [Quickstart](https://docs.composio.dev/docs/quickstart).

1. **Create a Composio account** and project at [dashboard.composio.dev](https://dashboard.composio.dev).
2. **Get the API key** from [Settings](https://dashboard.composio.dev/settings). This is the project-scoped key used in the `x-api-key` header. In ARCA, store it **server-side or in the app's bundle/Keychain** — note it is a project secret; for a single-tenant demo booth app, embedding it in the signed app (ideally Keychain) is acceptable, but it grants full project access, so do not ship it in a public repo.
3. **Create one Auth Config per toolkit** on the dashboard ([dashboard.composio.dev/.../auth-configs](https://dashboard.composio.dev)):
   - Pick the toolkit: `GMAIL`, `SLACK`, `NOTION`, `GOOGLECALENDAR`, `GITHUB`.
   - Pick auth method (OAuth2 for all of these).
   - For OAuth: **"development uses Composio's managed auth"** — "Composio registers and maintains OAuth apps for popular toolkits (GitHub, Gmail, Slack, etc.). Zero setup, works out of the box." So for the demo you do **not** need to register your own Google/Slack OAuth app. (For production branding — users see "ARCA" instead of "Composio" — you'd switch to custom auth with your own client id/secret.)
   - Click "Create Auth Configuration" and **note the `auth_config_id`** (format `ac_…`). One per toolkit. These are the IDs you hardcode/config in ARCA.
   - Source for managed-auth quote: [Managed vs custom auth](https://docs.composio.dev/docs/custom-app-vs-managed-app).

### Pricing / free tier (visible 2026)
Source: [Composio Pricing](https://composio.dev/pricing).
- **Free ("Totally Free"): $0/mo, 20,000 tool calls/month**, community support, no credit card.
- "Ridiculously Cheap": $29/mo, 200k calls/mo, then $0.299 / 1k.
- "Serious Business": $229/mo, 2M calls/mo, then $0.249 / 1k.
- Enterprise: custom (SOC-2, VPC/on-prem).
- Metering is **per tool call**, not per connected account — a booth demo fits comfortably in free tier.

---

## 2. Connect flow — exact REST sequence (the HeyClicky flow)

Sources: [Connected Accounts](https://docs.composio.dev/docs/auth-configuration/connected-accounts), [Authenticating Tools](https://docs.composio.dev/docs/authenticating-tools), [Create a new connected account](https://docs.composio.dev/reference/api-reference/connected-accounts/postConnectedAccounts), [Get connected account by ID](https://docs.composio.dev/reference/v3/api-reference/connected-accounts/getConnectedAccountsByNanoid).

### Step A — Initiate the connection (get the consent URL)

There are two REST routes. **Prefer `link` (hosted).**

#### Preferred: `POST /api/v3/connected_accounts/link`
This is the route the SDK's `connected_accounts.link()` / `connectedAccounts.link()` wraps; it is the **replacement** for the legacy initiate path for Composio-managed OAuth2 (see Deprecation note below).

```
POST https://backend.composio.dev/api/v3/connected_accounts/link
Headers:
  x-api-key: <COMPOSIO_API_KEY>
  Content-Type: application/json
Body:
{
  "user_id": "arca-booth-user-001",
  "auth_config_id": "ac_GMAIL_xxx",
  "callback_url": "https://your-app.com/callback"   // OPTIONAL — see desktop note below
}
```
Response (the fields ARCA needs):
```json
{
  "id": "ca_AbC123...",            // connected account id — keep this
  "redirect_url": "https://backend.composio.dev/...consent...",  // open in browser
  "status": "INITIALIZING"          // or INITIATED / PENDING
}
```

#### Legacy/general: `POST /api/v3/connected_accounts`
Wraps `connected_accounts.initiate()`. Use for **custom** auth configs or non-OAuth (API-key/bearer) schemes. Body shape (more verbose):
```json
{
  "auth_config": { "id": "ac_xxx" },
  "connection": {
    "user_id": "arca-booth-user-001",
    "callback_url": "https://your-app.com/callback",
    "state": { "authScheme": "OAUTH2", "val": { "status": "INITIATED" } }
  }
}
```
Response:
```json
{
  "id": "ca_...",
  "status": "INITIALIZING",
  "redirect_url": "https://...",   // (also surfaced as redirect_uri in some responses)
  "connectionData": { "authScheme": "OAUTH2", "val": { "status": "..." } }
}
```

> **Deprecation note (verify before shipping):** Per the changelog, the legacy `connected_accounts` *initiate* path for **Composio-managed** OAuth1/OAuth2/DCR schemes begins returning `400 BadRequest` (rollout 2026-05-08 → 2026-07-03) and callers must migrate to **`POST /api/v3/connected_accounts/link`**. Custom auth configs and non-OAuth schemes still use the older path. **Net: for ARCA's managed-OAuth Gmail/Slack/Notion/Calendar/GitHub, use `/connected_accounts/link`.** Source: [Changelog](https://docs.composio.dev/docs/changelog) (flag: exact dates/behavior should be re-confirmed at build time).

### Step B — Open the consent URL in the system browser
```swift
NSWorkspace.shared.open(URL(string: redirectURL)!)
```
Composio hosts the OAuth consent ("Secured by Composio") and **hosts the callback** at its own backend (`https://backend.composio.dev/api/v3.1/toolkits/auth/callback`). Source: [Authenticating Tools](https://docs.composio.dev/docs/authenticating-tools).

### Step C — Poll until ACTIVE
```
GET https://backend.composio.dev/api/v3/connected_accounts/{id}
Headers:
  x-api-key: <COMPOSIO_API_KEY>
```
Response includes `status` among: `INITIALIZING | INITIATED | ACTIVE | FAILED | EXPIRED`. Poll every few seconds until `status == "ACTIVE"`. Only **ACTIVE** accounts can execute tools. Source: [Get connected account by ID](https://docs.composio.dev/reference/v3/api-reference/connected-accounts/getConnectedAccountsByNanoid).

Response (trimmed, relevant fields):
```json
{
  "id": "ca_AbC123",
  "user_id": "arca-booth-user-001",
  "status": "ACTIVE",
  "toolkit": { "slug": "gmail" },
  "auth_config": { "id": "ac_GMAIL_xxx", "is_composio_managed": true },
  "created_at": "...", "updated_at": "..."
}
```
(Token fields like `access_token`/`refresh_token` are masked to first 4 chars by default — ARCA never needs them; Composio executes on your behalf.)

> This is exactly what the SDK's `wait_for_connection()` / `waitForConnection()` does internally — repeated GETs on the connected-account id until ACTIVE/failed/timeout. ARCA reimplements that poll loop in Swift.

---

## 3. Execute / read actions

Source: [Execute tool](https://docs.composio.dev/api-reference/tools/post-tools-execute-by-tool-slug), [Proxy execute](https://docs.composio.dev/docs/proxy-execute), toolkit pages ([Gmail](https://docs.composio.dev/toolkits/gmail), [Slack](https://docs.composio.dev/toolkits/slack), [Google Calendar](https://docs.composio.dev/toolkits/googlecalendar), [Notion](https://composio.dev/toolkits/notion)).

### The execute endpoint
```
POST https://backend.composio.dev/api/v3/tools/execute/{TOOL_SLUG}
Headers:
  x-api-key: <COMPOSIO_API_KEY>
  Content-Type: application/json
Body:
{
  "connected_account_id": "ca_AbC123",   // which user's account to act as
  "arguments": { /* action-specific params */ }
  // alternatively "user_id": "arca-booth-user-001" lets Composio pick the
  // ACTIVE connected account for that user+toolkit.
}
```
**Response shape:**
```json
{
  "data": { /* action result payload */ },
  "error": null,
  "successful": true
}
```
On auth failure (neither `connected_account_id` nor connection context): `400 MissingAuthContext` with `error: { message, code }`. Source: [Proxy execute](https://docs.composio.dev/docs/proxy-execute).

### (a) Gmail — list recent + send
Source: [Gmail toolkit](https://docs.composio.dev/toolkits/gmail).
- **List/fetch:** `GMAIL_FETCH_EMAILS`
  args: `query`, `label_ids`, `max_results`, `page_token`, `include_payload`, `verbose`.
  ```
  POST /api/v3/tools/execute/GMAIL_FETCH_EMAILS
  { "connected_account_id":"ca_...", "arguments": { "max_results": 10, "query": "is:unread" } }
  ```
- **Send:** `GMAIL_SEND_EMAIL`
  args: `recipient_email`, `subject`, `body`, `cc`, `bcc`, `attachment`, `is_html`.
  ```
  POST /api/v3/tools/execute/GMAIL_SEND_EMAIL
  { "connected_account_id":"ca_...", "arguments": {
      "recipient_email":"a@b.com", "subject":"hi", "body":"<p>...</p>", "is_html":true } }
  ```
- Related: `GMAIL_CREATE_EMAIL_DRAFT`, `GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID`, `GMAIL_LIST_THREADS`.

### (b) Slack — read recent + post
Source: [Slack toolkit](https://docs.composio.dev/toolkits/slack).
- **Read recent:** `SLACK_FETCH_CONVERSATION_HISTORY`
  args: `channel` (required), `limit` (1–1000, default 100), `cursor`, `oldest`, `latest`.
  (For thread replies: `SLACK_FETCH_MESSAGE_THREAD_FROM_A_CONVERSATION` with `thread_ts`.)
- **Post:** `SLACK_SEND_MESSAGE` (newer slug; `SLACK_CHAT_POST_MESSAGE` is deprecated)
  args: `channel` (id or name, required), `markdown_text`/`text`, `thread_ts`, `blocks`/`attachments`.
  ```
  POST /api/v3/tools/execute/SLACK_SEND_MESSAGE
  { "connected_account_id":"ca_...", "arguments": { "channel":"#general", "markdown_text":"hi" } }
  ```

### (c) Notion — read
Source: [Notion toolkit](https://composio.dev/toolkits/notion).
- **Read:** `NOTION_FETCH_DATA` — "fetches Notion items (pages and/or databases) from the workspace."
  (Other common slugs: `NOTION_QUERY_DATABASE`, `NOTION_CREATE_PAGE`, `NOTION_FETCH_BLOCK`. Confirm exact slugs/args at build time via the dashboard tool browser or `composio tools info <SLUG>` — flag: not all slugs verified line-by-line here.)

### (d) Google Calendar — read
Source: [Google Calendar toolkit](https://docs.composio.dev/toolkits/googlecalendar).
- **List events:** `GOOGLECALENDAR_EVENTS_LIST` (list upcoming/past/filtered events; `GOOGLECALENDAR_FIND_EVENT` for search). Create: `GOOGLECALENDAR_CREATE_EVENT`.
  (Flag: exact arg names — `calendar_id`, `timeMin`/`timeMax`, `max_results` — confirm via dashboard tool browser before shipping.)

> **Tip:** For any slug, the canonical args are discoverable at runtime via `GET /api/v3/tools/{TOOL_SLUG}` (the tool's input JSON schema) or the dashboard's tool browser. ARCA can hardcode the five demo actions above and skip dynamic discovery.

---

## 4. Auth header + base URL (canonical)

| Item | Value |
|---|---|
| Base URL | `https://backend.composio.dev/api/v3` (newer routes `…/api/v3.1`) |
| Auth header (project) | `x-api-key: <COMPOSIO_API_KEY>` |
| Auth header (org) | `x-org-api-key: <ORG_KEY>` (not needed for ARCA) |
| Content type | `Content-Type: application/json` |
| Hosted OAuth callback | `https://backend.composio.dev/api/v3.1/toolkits/auth/callback` (Composio-hosted; you don't run it) |

Sources: [API Reference](https://docs.composio.dev/reference), [Authenticating Tools](https://docs.composio.dev/docs/authenticating-tools).

---

## 5. Swift client sketch (`URLSession`, async/await)

Concrete endpoint paths/fields baked in. Pure Swift, no dependencies.

```swift
import Foundation
import AppKit  // NSWorkspace

struct ComposioConfig {
    static let baseURL = URL(string: "https://backend.composio.dev/api/v3")!
}

enum ComposioError: Error { case http(Int, Data), notActive, timeout }

final class Composio {
    private let apiKey: String
    private let session: URLSession
    private let base = ComposioConfig.baseURL

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: low-level request
    private func request(_ method: String, _ path: String,
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ComposioError.http(code, data) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: 1) initiate (hosted link)  -> (connectionId, redirectURL)
    // POST /connected_accounts/link
    func initiateConnection(authConfigId: String, userId: String,
                            callbackURL: String? = nil) async throws -> (id: String, redirectURL: String) {
        var body: [String: Any] = ["user_id": userId, "auth_config_id": authConfigId]
        if let callbackURL { body["callback_url"] = callbackURL }
        let json = try await request("POST", "connected_accounts/link", body: body)
        guard let id = json["id"] as? String,
              let url = (json["redirect_url"] as? String) ?? (json["redirect_uri"] as? String)
        else { throw ComposioError.http(0, Data()) }
        return (id, url)
    }

    // Open consent page in default browser (Composio hosts consent + callback)
    func openConsent(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: 2) poll until ACTIVE
    // GET /connected_accounts/{id}
    func status(connectionId: String) async throws -> String {
        let json = try await request("GET", "connected_accounts/\(connectionId)")
        return (json["status"] as? String) ?? "UNKNOWN"
    }

    func waitUntilActive(connectionId: String,
                         timeout: TimeInterval = 180, interval: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = try await status(connectionId: connectionId)
            if s == "ACTIVE" { return }
            if s == "FAILED" || s == "EXPIRED" { throw ComposioError.notActive }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw ComposioError.timeout
    }

    // MARK: 3) execute a tool action -> JSON
    // POST /tools/execute/{TOOL_SLUG}
    @discardableResult
    func execute(action: String, connectionId: String,
                 arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let body: [String: Any] = ["connected_account_id": connectionId, "arguments": arguments]
        let json = try await request("POST", "tools/execute/\(action)", body: body)
        // shape: { data: {...}, error: null, successful: true }
        return json
    }
}
```

### Usage (Gmail demo)
```swift
let cmp = Composio(apiKey: KEY)
let (connId, url) = try await cmp.initiateConnection(
    authConfigId: "ac_GMAIL_xxx", userId: "arca-booth-user-001")
cmp.openConsent(url)                       // browser opens "Secured by Composio"
try await cmp.waitUntilActive(connectionId: connId)   // polls GET until ACTIVE
let inbox = try await cmp.execute(action: "GMAIL_FETCH_EMAILS",
    connectionId: connId, arguments: ["max_results": 10])
try await cmp.execute(action: "GMAIL_SEND_EMAIL", connectionId: connId,
    arguments: ["recipient_email":"a@b.com","subject":"ARCA","body":"hi"])
```

**Client signature summary:**
- `init(apiKey:)`
- `initiateConnection(authConfigId:userId:callbackURL:) -> (id, redirectURL)`
- `waitUntilActive(connectionId:timeout:interval:)`
- `execute(action:connectionId:arguments:) -> JSON`

---

## 6. Gotchas / desktop-specific notes

1. **Callback handling (the key desktop question):** Composio **hosts the OAuth callback** at `backend.composio.dev/api/v3.1/toolkits/auth/callback`. ARCA does **not** need to run a localhost server or register a custom URL scheme. The `callback_url` field is only where Composio redirects the *browser* after success (a nice "you can close this tab" page). **ARCA detects completion by polling `GET /connected_accounts/{id}` for `ACTIVE`** — not by intercepting the redirect. (Optional nicety: pass a `arca://connected` custom scheme as `callback_url` to auto-foreground the app, but polling alone is sufficient and is what HeyClicky-style apps rely on.) Source: [Authenticating Tools](https://docs.composio.dev/docs/authenticating-tools).
2. **Token refresh is fully managed by Composio.** "Composio automatically refreshes OAuth tokens before they expire." ARCA never sees or stores access/refresh tokens — it only stores `connected_account_id`s. Source: [Composio](https://composio.dev/), [Connected Accounts](https://docs.composio.dev/docs/auth-configuration/connected-accounts).
3. **Managed-auth polling floor:** managed auth "enforces a 15-minute minimum polling interval" for *connection-status refresh internals* and shares OAuth quota across all Composio users; a custom OAuth app gives dedicated quota + shorter intervals. For a live booth demo, prefer **custom auth** (your own Google/Slack client id) to avoid shared-quota flakiness and to brand the consent as "ARCA". Source: [Managed vs custom auth](https://docs.composio.dev/docs/custom-app-vs-managed-app).
4. **Rate limits:** plan-tiered, ~2,000–10,000 requests/min. Free tier = 20k tool calls/month. Source: [API Reference](https://docs.composio.dev/reference), [Pricing](https://composio.dev/pricing).
5. **`user_id` is your identity, not Composio's.** It's an arbitrary string you choose to scope a person's connections. Same `user_id` can hold multiple accounts per toolkit (personal + work Gmail) — use `allow_multiple`/`alias` if needed. Source: [Connected Accounts](https://docs.composio.dev/docs/auth-configuration/connected-accounts).
6. **Use `/connected_accounts/link`, not the legacy initiate, for managed OAuth** — the legacy managed-OAuth initiate path is being retired in 2026 (returns 400). Re-confirm dates at build time. Source: [Changelog](https://docs.composio.dev/docs/changelog).
7. **Slug drift:** Slack `SLACK_CHAT_POST_MESSAGE` is deprecated in favor of `SLACK_SEND_MESSAGE`; verify exact slugs for Notion/Calendar via the dashboard tool browser or `GET /api/v3/tools/{slug}` before hardcoding. Source: [Slack toolkit](https://docs.composio.dev/toolkits/slack).
8. **API key sensitivity:** `x-api-key` is a project-wide secret. In a distributed app it can be extracted from the binary. For a single-booth demo, store in Keychain; for any public distribution, front Composio with a thin proxy that holds the key. (No public HeyClicky source was found to confirm their exact key handling — flag.)

---

## Unverified / to confirm at build time
- Exact 2026 deprecation dates and whether `/connected_accounts/link` fully replaces `initiate` for all five toolkits (re-check [Changelog](https://docs.composio.dev/docs/changelog)).
- Exact arg schemas for `NOTION_*` and `GOOGLECALENDAR_*` slugs (use dashboard tool browser / `GET /api/v3/tools/{slug}`).
- HeyClicky's specific implementation details — no public source/docs found; the flow above is reconstructed from Composio's own hosted-auth docs, which match the described HeyClicky behavior ("Connect" → Composio-hosted consent → act on tool).

## Primary sources
- https://docs.composio.dev/docs/auth-configuration/connected-accounts
- https://docs.composio.dev/docs/authenticating-tools
- https://docs.composio.dev/docs/custom-app-vs-managed-app
- https://docs.composio.dev/reference/api-reference/connected-accounts/postConnectedAccounts
- https://docs.composio.dev/reference/v3/api-reference/connected-accounts/getConnectedAccountsByNanoid
- https://docs.composio.dev/api-reference/tools/post-tools-execute-by-tool-slug
- https://docs.composio.dev/docs/proxy-execute
- https://docs.composio.dev/toolkits/gmail · /slack · /googlecalendar · https://composio.dev/toolkits/notion
- https://composio.dev/pricing
- https://docs.composio.dev/reference (base URL + headers)
- https://docs.composio.dev/docs/changelog (deprecation)
