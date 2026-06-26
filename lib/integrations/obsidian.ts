import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { obsidianVaultPath, obsidianSubfolder } from "@/lib/config";
import { memoryToMarkdown, slugify } from "@/lib/render";
import type { Memory, IntegrationResult } from "@/lib/types";

export async function pushToObsidian(memory: Memory): Promise<IntegrationResult> {
  const at = new Date().toISOString();
  const vault = obsidianVaultPath();

  if (!vault) {
    return {
      target: "obsidian",
      status: "skipped",
      detail: "Set OBSIDIAN_VAULT_PATH to sync notes into a vault.",
      at,
    };
  }

  try {
    const date = memory.createdAt.slice(0, 10); // YYYY-MM-DD
    const slug = slugify(memory.analysis.title);
    const folder = join(vault, obsidianSubfolder());
    const filePath = join(folder, `${date}-${slug}.md`);

    await mkdir(folder, { recursive: true });
    await writeFile(filePath, memoryToMarkdown(memory), "utf-8");

    return {
      target: "obsidian",
      status: "success",
      detail: filePath,
      at,
    };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      target: "obsidian",
      status: "error",
      detail: message,
      at,
    };
  }
}
