#!/usr/bin/env node
/**
 * Screenshot every ARCA surface (desktop + mobile) for design audit.
 * Each page/viewport is isolated: a hang or crash on one never kills the run.
 * Usage: node scripts/audit-screenshots.mjs [outDir]
 */
import puppeteer from "puppeteer-core";
import { mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const OUT = process.argv[2] || join(ROOT, "tmp", "audit");
mkdirSync(OUT, { recursive: true });

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const BASE = "http://localhost:4174";

const PAGES = [
  { slug: "home", path: "/" },
  { slug: "arca", path: "/arca" },
  { slug: "arcaos", path: "/arcaos" },
  { slug: "arcaconnect", path: "/arcaconnect" },
  { slug: "arcademo", path: "/arcademo" },
  { slug: "arcaservice", path: "/arcaservice" },
];

const VIEWPORTS = [
  { tag: "desktop", width: 1440, height: 900 },
  { tag: "mobile", width: 390, height: 844 },
];

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: "new",
  protocolTimeout: 45000,
  args: ["--no-sandbox", "--hide-scrollbars"],
});

const consoleErrors = {};
const failures = [];

for (const { slug, path } of PAGES) {
  for (const vp of VIEWPORTS) {
    // Fresh page per shot so one wedged renderer can't poison the next.
    const page = await browser.newPage();
    page.on("console", (msg) => {
      if (msg.type() === "error") {
        (consoleErrors[`${slug}-${vp.tag}`] ||= []).push(msg.text().slice(0, 300));
      }
    });
    page.on("pageerror", (e) => {
      (consoleErrors[`${slug}-${vp.tag}`] ||= []).push(`pageerror: ${String(e).slice(0, 300)}`);
    });

    try {
      await page.setViewport({ width: vp.width, height: vp.height, deviceScaleFactor: 2 });
      await page
        .goto(`${BASE}${path}`, { waitUntil: "networkidle0", timeout: 25000 })
        .catch(() => page.goto(`${BASE}${path}`, { waitUntil: "domcontentloaded", timeout: 25000 }));
      await new Promise((r) => setTimeout(r, 2200));

      // fullPage hangs on pages with infinite animations — scroll & shoot.
      const total = await page.evaluate(() => document.body.scrollHeight);
      const steps = Math.min(4, Math.max(1, Math.ceil(total / vp.height)));
      for (let s = 0; s < steps; s++) {
        const y = Math.round((total - vp.height) * (steps === 1 ? 0 : s / (steps - 1)));
        await page.evaluate((yy) => window.scrollTo(0, yy), y);
        await new Promise((r) => setTimeout(r, 800));
        await page.screenshot({ path: join(OUT, `${slug}-${vp.tag}-${s}.png`) });
      }
      console.log(`✓ ${slug} ${vp.tag} (${steps} shots)`);
    } catch (err) {
      failures.push(`${slug}-${vp.tag}: ${String(err).slice(0, 160)}`);
      console.log(`✗ ${slug} ${vp.tag}`);
    } finally {
      await page.close().catch(() => {});
    }
  }
}

console.log("\n== console errors ==\n" + JSON.stringify(consoleErrors, null, 2));
if (failures.length) console.log("\n== failures ==\n" + failures.join("\n"));
await browser.close();
process.exit(0);
