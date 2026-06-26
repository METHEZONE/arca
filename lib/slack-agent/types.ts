export type SlackAgentMode = "dm" | "mention" | "ignored";

export interface SlackEventEnvelope {
  token?: string;
  challenge?: string;
  type: "url_verification" | "event_callback" | string;
  event_id?: string;
  event_time?: number;
  team_id?: string;
  event?: SlackMessageEvent;
}

export interface SlackMessageEvent {
  type: string;
  subtype?: string;
  user?: string;
  bot_id?: string;
  channel?: string;
  channel_type?: "im" | "channel" | "group" | "mpim" | string;
  text?: string;
  ts?: string;
  thread_ts?: string;
}

export interface SlackAgentDecision {
  mode: SlackAgentMode;
  shouldReply: boolean;
  replyText: string;
  risk: "low" | "medium" | "high";
  actionSummary: string;
  needsHumanApproval: boolean;
  reason: string;
}

export interface SlackPostResult {
  ok: boolean;
  detail: string;
  ts?: string;
}

export interface PendingSlackAction {
  id: string;
  createdAt: string;
  teamId?: string;
  eventId?: string;
  channel: string;
  threadTs: string;
  user?: string;
  text: string;
  decision: SlackAgentDecision;
}
