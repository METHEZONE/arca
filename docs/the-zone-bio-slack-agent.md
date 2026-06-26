# THE ZONE BIO Slack Agent

This agent receives Slack Events API callbacks for direct messages and bot mentions, drafts a THE ZONE BIO-style reply, and either queues it for approval or posts it back to Slack.

It is intentionally implemented as a Slack App bot, not a personal user-token selfbot. Personal account automation is fragile and high-risk. The bot can still be named and styled as your assistant, while preserving explicit permissions and auditability.

## What It Handles

- Personal DM to the app: `message.im`
- Channel mention: `app_mention`-style message text containing `<@SLACK_APP_BOT_USER_ID>`
- THE ZONE BIO tone: concise Korean, practical, declarative
- External actions: queued as high-risk pending actions by default
- Approval-first mode: pending actions are written to `data/slack-agent/pending-actions.jsonl`

## Environment

Add these to `.env.local`:

```bash
SLACK_SIGNING_SECRET=
SLACK_BOT_TOKEN=
SLACK_APP_BOT_USER_ID=
SLACK_AGENT_OWNER_USER_ID=

# Optional: restrict mention replies to channel IDs, comma-separated.
SLACK_AGENT_MENTION_CHANNELS=

# Safe defaults.
SLACK_AGENT_DRY_RUN=true
SLACK_AGENT_AUTO_REPLY=false
SLACK_AGENT_REQUIRE_APPROVAL=true
SLACK_AGENT_MODEL_TIMEOUT_MS=1500

# Optional LLM reply drafting. Without this, rule-based Korean replies are used.
OPENAI_API_KEY=
OPENAI_NOTES_MODEL=gpt-5.5
```

## Slack App Setup

Create a Slack App and point Event Subscriptions to:

```text
https://YOUR_PUBLIC_HOST/api/slack/agent
```

For local development, expose Next.js with a tunnel and use the tunnel URL.

Subscribe to bot events:

```text
message.channels
message.groups
message.im
message.mpim
app_mention
```

Maximum useful bot scopes for the current agent:

```text
app_mentions:read
channels:history
channels:read
chat:write
chat:write.customize
groups:history
groups:read
im:history
im:read
im:write
mpim:history
mpim:read
users:read
```

If the workspace allows user-event subscriptions and you want ARCA to receive events from conversations visible to the installing user, also add user token scopes:

```text
channels:history
groups:history
im:history
mpim:history
users:read
```

Then subscribe to user events:

```text
message.channels
message.groups
message.im
message.mpim
```

If you restrict channel mentions through `SLACK_AGENT_MENTION_CHANNELS`, use channel IDs such as `C0123456789`, not names.

You can start from the ready-to-import manifest:

```text
.slack/manifest.the-zone-bio-arca.yml
```

Replace `https://YOUR_PUBLIC_HOST` with your deployed or tunneled host before importing.

## Owner Mentions Without `@ARCA`

Set:

```bash
SLACK_AGENT_OWNER_USER_ID=U_YOUR_SLACK_MEMBER_ID
```

When ARCA receives a channel/private-channel/group-DM message that contains `<@U_YOUR_SLACK_MEMBER_ID>`, it treats the message as a mention even if the sender did not call `@ARCA`.

Important boundary: Slack only sends events the app is allowed to see. For channels, invite the app to the channel. For user-event subscriptions, the installing user and workspace/admin policy decide what conversation events are available.

## Run

```bash
npm run dev
```

Health check:

```bash
curl http://localhost:4174/api/slack/agent
```

Smoke test:

```bash
SLACK_SIGNING_SECRET=dev-secret node scripts/slack-agent-smoke.mjs
SLACK_SIGNING_SECRET=dev-secret npm run slack-agent:smoke:owner-mention
```

The smoke test sends a signed fake DM event. With the safe defaults, it should queue an approval item instead of posting to Slack.

## Going Live

Only after confirming behavior in `pending-actions.jsonl`:

```bash
SLACK_AGENT_DRY_RUN=false
SLACK_AGENT_AUTO_REPLY=true
SLACK_AGENT_REQUIRE_APPROVAL=false
```

Keep `SLACK_AGENT_REQUIRE_APPROVAL=true` if the agent is allowed to draft external actions such as sending customer messages, editing orders, booking, deleting, uploading, or changing production data.
