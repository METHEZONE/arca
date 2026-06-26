import crypto from "node:crypto";

const url = process.argv[2] ?? "http://localhost:4174/api/slack/agent";
const scenario = process.env.SLACK_AGENT_SMOKE_SCENARIO ?? "dm";
const secret = process.env.SLACK_SIGNING_SECRET ?? "dev-secret";
const event =
  scenario === "owner-mention"
    ? {
        type: "message",
        channel_type: "channel",
        channel: "C_DEV",
        user: "U_DEV",
        text: "<@U_OWNER> 이번 주문 건 확인해줘",
        ts: `${Math.floor(Date.now() / 1000)}.000100`,
      }
    : {
        type: "message",
        channel_type: "im",
        channel: "D_DEV",
        user: "U_DEV",
        text: "이번 주문 건 확인해줘",
        ts: `${Math.floor(Date.now() / 1000)}.000100`,
      };
const body = JSON.stringify({
  type: "event_callback",
  team_id: "T_DEV",
  event_id: `Ev_${Date.now()}`,
  event,
});

const ts = Math.floor(Date.now() / 1000).toString();
const signature = `v0=${crypto
  .createHmac("sha256", secret)
  .update(`v0:${ts}:${body}`)
  .digest("hex")}`;

const res = await fetch(url, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "x-slack-request-timestamp": ts,
    "x-slack-signature": signature,
  },
  body,
});

const text = await res.text();
console.log(`${res.status} ${text}`);
if (!res.ok) process.exit(1);
