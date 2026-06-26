import type { Memory, IntegrationResult, IntegrationTarget } from "@/lib/types";
import { pushToObsidian } from "@/lib/integrations/obsidian";
import { pushToNotion } from "@/lib/integrations/notion";
import { pushToSlack } from "@/lib/integrations/slack";

const PUSH_FNS: Record<IntegrationTarget, (memory: Memory) => Promise<IntegrationResult>> = {
  obsidian: pushToObsidian,
  notion: pushToNotion,
  slack: pushToSlack,
};

export async function pushToTargets(
  memory: Memory,
  targets: IntegrationTarget[],
): Promise<IntegrationResult[]> {
  return Promise.all(targets.map((target) => PUSH_FNS[target](memory)));
}
