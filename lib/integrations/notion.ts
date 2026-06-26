import { notionKey, notionDatabaseId } from "@/lib/config";
import type { Memory, IntegrationResult } from "@/lib/types";

// ---------------------------------------------------------------------------
// Notion block helpers
// ---------------------------------------------------------------------------

type RichText = { type: "text"; text: { content: string } };
type NotionBlock =
  | { object: "block"; type: "heading_2"; heading_2: { rich_text: RichText[] } }
  | { object: "block"; type: "paragraph"; paragraph: { rich_text: RichText[] } }
  | { object: "block"; type: "bulleted_list_item"; bulleted_list_item: { rich_text: RichText[] } }
  | { object: "block"; type: "to_do"; to_do: { checked: boolean; rich_text: RichText[] } };

function rt(content: string): RichText[] {
  return [{ type: "text", text: { content: content.slice(0, 2000) } }];
}

function heading2(text: string): NotionBlock {
  return { object: "block", type: "heading_2", heading_2: { rich_text: rt(text) } };
}

function paragraph(text: string): NotionBlock {
  return { object: "block", type: "paragraph", paragraph: { rich_text: rt(text) } };
}

function bullet(text: string): NotionBlock {
  return {
    object: "block",
    type: "bulleted_list_item",
    bulleted_list_item: { rich_text: rt(text) },
  };
}

function todo(text: string, checked: boolean): NotionBlock {
  return { object: "block", type: "to_do", to_do: { checked, rich_text: rt(text) } };
}

function buildChildren(memory: Memory): NotionBlock[] {
  const { analysis } = memory;
  const blocks: NotionBlock[] = [];

  blocks.push(heading2("Summary"));
  blocks.push(paragraph(analysis.summary));

  if (analysis.decisions.length) {
    blocks.push(heading2("Decisions"));
    for (const d of analysis.decisions) {
      blocks.push(bullet(d.text));
    }
  }

  if (analysis.actionItems.length) {
    blocks.push(heading2("Action plan"));
    for (const a of analysis.actionItems) {
      const parts: string[] = [a.title];
      if (a.owner) parts.push(`@${a.owner}`);
      if (a.due) parts.push(a.due);
      parts.push(`[${a.priority}]`);
      blocks.push(todo(parts.join(" · "), a.status === "done"));
    }
  }

  if (analysis.openQuestions.length) {
    blocks.push(heading2("Open questions"));
    for (const q of analysis.openQuestions) {
      blocks.push(bullet(q));
    }
  }

  if (analysis.followups.length) {
    blocks.push(heading2("Follow-ups"));
    for (const f of analysis.followups) {
      blocks.push(paragraph(f));
    }
  }

  return blocks;
}

// ---------------------------------------------------------------------------
// Main push function
// ---------------------------------------------------------------------------

interface NotionPageResponse {
  id?: string;
  url?: string;
  object?: string;
  status?: number;
  message?: string;
}

async function postPage(
  key: string,
  databaseId: string,
  titleKey: string,
  memory: Memory,
): Promise<Response> {
  const body = {
    parent: { database_id: databaseId },
    properties: {
      [titleKey]: {
        title: [{ text: { content: memory.analysis.title.slice(0, 200) } }],
      },
    },
    children: buildChildren(memory),
  };

  return fetch("https://api.notion.com/v1/pages", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Notion-Version": "2022-06-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

export async function pushToNotion(memory: Memory): Promise<IntegrationResult> {
  const at = new Date().toISOString();
  const key = notionKey();
  const databaseId = notionDatabaseId();

  if (!key || !databaseId) {
    return {
      target: "notion",
      status: "skipped",
      detail: "Set NOTION_API_KEY and NOTION_DATABASE_ID.",
      at,
    };
  }

  try {
    let res = await postPage(key, databaseId, "Name", memory);

    // Retry with "title" key if "Name" caused a property-related 400
    if (res.status === 400) {
      const bodyText = await res.text();
      if (bodyText.includes("propert")) {
        res = await postPage(key, databaseId, "title", memory);
        if (!res.ok) {
          const errText = await res.text();
          return {
            target: "notion",
            status: "error",
            detail: `notion ${res.status}: ${errText.slice(0, 200)}`,
            at,
          };
        }
      } else {
        return {
          target: "notion",
          status: "error",
          detail: `notion ${res.status}: ${bodyText.slice(0, 200)}`,
          at,
        };
      }
    } else if (!res.ok) {
      const errText = await res.text();
      return {
        target: "notion",
        status: "error",
        detail: `notion ${res.status}: ${errText.slice(0, 200)}`,
        at,
      };
    }

    const data = (await res.json()) as NotionPageResponse;
    return {
      target: "notion",
      status: "success",
      detail: data.url ?? data.id ?? "created",
      at,
    };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      target: "notion",
      status: "error",
      detail: message,
      at,
    };
  }
}
