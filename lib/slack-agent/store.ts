import { mkdir, appendFile } from "fs/promises";
import { join } from "path";

import { dataDir } from "@/lib/config";

import type { PendingSlackAction } from "./types";

export async function savePendingSlackAction(action: PendingSlackAction): Promise<void> {
  const dir = join(dataDir(), "slack-agent");
  await mkdir(dir, { recursive: true });
  await appendFile(join(dir, "pending-actions.jsonl"), `${JSON.stringify(action)}\n`, "utf8");
}
