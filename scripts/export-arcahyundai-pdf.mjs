#!/usr/bin/env node
/**
 * Export arcahyundai pitch deck → PDF
 * Uses puppeteer-core + system Chrome to screenshot each slide,
 * then assembles into a multi-page PDF.
 *
 * Usage: node scripts/export-arcahyundai-pdf.mjs
 */

import puppeteer from "puppeteer-core";
import { writeFileSync, mkdirSync, rmSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { spawn, execSync } from "child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const OUT_DIR = join(ROOT, "tmp", "pdf-export");
const PDF_PATH = join(ROOT, "arcahyundai-pitch.pdf");

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const BASE_URL = "http://localhost:4174";
const SLIDE_URL = (n) => `${BASE_URL}/arcahyundai?slide=${n}&present=1`;
const TOTAL_SLIDES = 24;

// Slide width × height (16:9 presentation)
const W = 1920;
const H = 1080;

// ─── helpers ─────────────────────────────────────────────────────────────────

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForServer(url, timeoutMs = 30_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
      if (res.ok || res.status === 404) return true;
    } catch {}
    await sleep(800);
  }
  throw new Error(`Server at ${url} did not respond within ${timeoutMs}ms`);
}

// ─── main ─────────────────────────────────────────────────────────────────────

let devServer = null;

async function main() {
  // 1. Ensure output dir
  if (existsSync(OUT_DIR)) rmSync(OUT_DIR, { recursive: true });
  mkdirSync(OUT_DIR, { recursive: true });

  // 2. Check / start dev server
  let serverAlreadyUp = false;
  try {
    const r = await fetch(BASE_URL, { signal: AbortSignal.timeout(1500) });
    if (r.ok || r.status === 404) serverAlreadyUp = true;
  } catch {}

  if (!serverAlreadyUp) {
    console.log("⚡ Starting Next.js dev server...");
    devServer = spawn("npm", ["run", "dev"], {
      cwd: ROOT,
      stdio: "ignore",
      detached: false,
    });
    devServer.unref();
    await waitForServer(BASE_URL);
    await sleep(2000); // extra warm-up
    console.log("✓ Dev server ready");
  } else {
    console.log("✓ Dev server already running");
  }

  // 3. Launch browser
  console.log("🚀 Launching Chrome...");
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-web-security",
      "--disable-features=IsolateOrigins,site-per-process",
      `--window-size=${W},${H}`,
    ],
  });

  const page = await browser.newPage();
  await page.setViewport({ width: W, height: H, deviceScaleFactor: 2 });

  // Suppress external resource errors (logo CDN might be blocked etc.)
  page.on("requestfailed", () => {});

  const screenshots = [];

  // 4. Screenshot each slide
  for (let idx = 0; idx < TOTAL_SLIDES; idx++) {
    const url = SLIDE_URL(idx);
    process.stdout.write(`  Slide ${String(idx + 1).padStart(2, "0")}/${TOTAL_SLIDES}  `);

    await page.goto(url, { waitUntil: "networkidle0", timeout: 15_000 }).catch(async () => {
      await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    });

    // Wait for framer-motion animations to settle
    await sleep(1600);

    const imgPath = join(OUT_DIR, `slide-${String(idx).padStart(3, "0")}.png`);
    await page.screenshot({ path: imgPath, type: "png" });
    screenshots.push(imgPath);
    console.log("✓");
  }

  await browser.close();
  console.log("\n📄 Assembling PDF...");

  // 5. Build PDF via a single-page print HTML
  const imgTags = screenshots
    .map(
      (p) =>
        `<div class="slide"><img src="file://${p}" width="${W}" height="${H}" /></div>`
    )
    .join("\n");

  const printHtml = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  @page { size: ${W}px ${H}px; margin: 0; }
  body { background: #000; }
  .slide {
    width: ${W}px;
    height: ${H}px;
    page-break-after: always;
    overflow: hidden;
  }
  .slide img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
</style>
</head>
<body>
${imgTags}
</body>
</html>`;

  const printHtmlPath = join(OUT_DIR, "print.html");
  writeFileSync(printHtmlPath, printHtml, "utf8");

  // 6. Print HTML → PDF
  const pdfBrowser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  });

  const pdfPage = await pdfBrowser.newPage();
  await pdfPage.goto(`file://${printHtmlPath}`, { waitUntil: "networkidle0" });

  await pdfPage.pdf({
    path: PDF_PATH,
    width: `${W}px`,
    height: `${H}px`,
    printBackground: true,
    margin: { top: 0, bottom: 0, left: 0, right: 0 },
  });

  await pdfBrowser.close();

  if (devServer) devServer.kill();

  console.log(`\n✅ PDF saved → ${PDF_PATH}`);
  console.log(`   ${TOTAL_SLIDES} slides · ${W}×${H}`);
}

main().catch((e) => {
  console.error("❌", e.message);
  if (devServer) devServer.kill();
  process.exit(1);
});
