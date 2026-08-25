import { chromium } from "playwright-core";
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";

// Sources and output both live beside this script.
const scratch = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const outDir = scratch;
fs.mkdirSync(outDir, { recursive: true });

const jobs = [
  { src: "readiness-brief.html", out: "Meridian-Readiness-Brief.pdf" },
  { src: "board-one-pager.html", out: "Meridian-Board-One-Pager.pdf" },
];

const browser = await chromium.launch({ channel: "chrome" });
const page = await browser.newPage();

for (const job of jobs) {
  const url = pathToFileURL(path.join(scratch, job.src)).href;
  await page.goto(url, { waitUntil: "networkidle", timeout: 60000 });

  // The whole point of using Playwright here: wait until the web fonts are
  // actually applied. Headless Chrome's --print-to-pdf raced them and silently
  // fell back to system faces, embedding only the one family that won.
  await page.evaluate(() => document.fonts.ready);
  const loaded = await page.evaluate(() =>
    [...document.fonts].filter((f) => f.status === "loaded").map((f) => `${f.family} ${f.weight}`)
  );
  const families = [...new Set(loaded.map((f) => f.split(" ").slice(0, -1).join(" ")))];
  console.log(`${job.src}: font families loaded -> ${families.join(", ") || "(none)"}`);

  // Print the light palette regardless of the machine's OS theme: a dark-mode
  // PDF of a document meant for paper is the classic export bug.
  await page.emulateMedia({ media: "print", colorScheme: "light" });

  // preferCSSPageSize defers to the document's own @page rule. Passing a margin
  // here as well made Chrome apply both, which pushed the one-pager onto a
  // second sheet even though its content fits.
  await page.pdf({
    path: path.join(outDir, job.out),
    printBackground: true,
    preferCSSPageSize: true,
  });

  const bytes = fs.statSync(path.join(outDir, job.out)).size;
  console.log(`${job.out}: ${bytes.toLocaleString()} bytes`);
}

await browser.close();
