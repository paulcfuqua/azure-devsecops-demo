/**
 * THE CHECK NOBODY HAD WRITTEN: does a browser actually render this app?
 *
 * `docs/DEMO-READINESS.md` section D names this gap, and 2026-09-01 evidenced it
 * five times over. Every one of these was found by a human opening the page, and
 * not one of them could have been caught by anything in CI:
 *
 *   F110  Easy Auth's id_token issuance was never enabled, so nobody could sign
 *         in - ever. V7.1 checks /healthz, which nginx answers without touching
 *         application code.
 *   F111  `ajv.compile()` needs 'unsafe-eval'; the CSP forbids it. Every spec
 *         was reported invalid IN A BROWSER and valid everywhere else, because
 *         Node has no CSP and the unit tests therefore could not see it.
 *   F116  One failed feed discarded the panels that had resolved, so a tab with
 *         data in hand rendered nothing.
 *   F117  The Ops tab rendered a fictional company's budget under a heading that
 *         invited the reader to take it for the platform's cost.
 *   F116b "Defender secure score 0.0%" - rendered from an empty API response, in
 *         a pixel, where no verification report exists to contradict it.
 *
 * WHAT THIS DOES. Serves the PRODUCTION bundle over HTTP with the PRODUCTION
 * Content-Security-Policy, drives real Chromium at it, and asserts that each tab
 * puts real content in the DOM with no console errors.
 *
 * TWO THINGS MAKE IT WORTH THE MINUTE IT COSTS, and both are properties a unit
 * test cannot have:
 *
 *   1. IT IS A REAL BROWSER WITH THE REAL CSP. The header is read out of
 *      `nginx.conf.template` rather than copied here, so it cannot drift from
 *      what the container serves. F111 is invisible without both halves - the
 *      policy AND an engine that enforces it.
 *   2. IT ASSERTS RENDERED CONTENT, not status codes. "The page loaded" was
 *      true on every one of the days above.
 *
 * WHAT IT DELIBERATELY DOES NOT DO. It runs in LOCAL_DATA mode against committed
 * fixtures, so it needs no tenant, no credential and no network. It therefore
 * proves the app renders the data it is given - not that the estate gives it the
 * right data. That second half is V7.6's job and they are complementary: V7.6
 * asserts the API answers with rows, this asserts a browser can draw them.
 */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = dirname(fileURLToPath(import.meta.url));
const appDir = resolve(here, "..");
const distDir = join(appDir, "dist");

/**
 * The production CSP, read from the template the container actually serves.
 *
 * Copying the string into this file would let the two drift, and the drift would
 * be silent in the direction that matters: a weakened production policy with a
 * strict copy here still passes. Reading it means a change to the real policy is
 * exercised by this check on the next run.
 */
function productionCsp() {
  const template = readFileSync(join(appDir, "nginx.conf.template"), "utf-8");
  const match = template.match(/add_header\s+Content-Security-Policy\s+"([^"]+)"/);
  if (!match) {
    throw new Error(
      "Could not find a Content-Security-Policy in nginx.conf.template. This check " +
        "asserts the app renders UNDER THE REAL POLICY; without one it would assert " +
        "nothing, so it fails rather than falling back to a permissive default.",
    );
  }
  return match[1];
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
};

function serve(csp) {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost");
    let filePath = join(distDir, decodeURIComponent(url.pathname));
    // SPA fallback, exactly as nginx does: unknown paths serve index.html.
    if (!existsSync(filePath) || url.pathname === "/") {
      filePath = join(distDir, "index.html");
    }
    try {
      const body = await readFile(filePath);
      res.writeHead(200, {
        "content-type": MIME[extname(filePath)] ?? "application/octet-stream",
        "content-security-policy": csp,
      });
      res.end(body);
    } catch (err) {
      res.writeHead(500).end(String(err));
    }
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok(server)));
}

/** Each tab, and the text that proves it drew something rather than an error. */
const TABS = [
  { name: "Dev", expect: ["Delivery health"] },
  { name: "Sec", expect: ["Security posture"] },
  { name: "Ops", expect: ["Platform run cost"] },
];

const failures = [];
function check(condition, message) {
  if (!condition) failures.push(message);
}

const csp = productionCsp();
const server = await serve(csp);
const { port } = server.address();
const browser = await chromium.launch();
const page = await browser.newPage();

const consoleErrors = [];
page.on("console", (msg) => {
  if (msg.type() === "error") consoleErrors.push(msg.text());
});
page.on("pageerror", (err) => consoleErrors.push(`pageerror: ${err.message}`));

try {
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle" });

  // IF THE APP NEVER MOUNTED, SAY SO IN THOSE WORDS.
  //
  // A CSP violation at module load stops React before it renders anything, so
  // the first thing that fails is a locator waiting for a tab that will never
  // exist - and Playwright reports a TimeoutError naming a selector, which tells
  // a reader nothing about the cause. The console errors collected above DO name
  // it. Surfacing them here is the difference between "the check failed" and
  // "the check told you what was wrong", which is the whole point of writing it.
  const tablist = page.getByRole("tab", { name: TABS[0].name, exact: true });
  try {
    await tablist.waitFor({ state: "visible", timeout: 15_000 });
  } catch {
    const detail = consoleErrors.length > 0
      ? `The browser reported: ${JSON.stringify(consoleErrors.slice(0, 5))}`
      : "The browser reported no console errors, so the bundle loaded but rendered nothing.";
    throw new Error(
      `The app never mounted - no tabs appeared within 15s. ${detail}`,
    );
  }

  for (const tab of TABS) {
    await page.getByRole("tab", { name: tab.name, exact: true }).click();
    // The renderer resolves its spec asynchronously; wait for the heading rather
    // than a fixed sleep, which would pass on a slow machine and fail on a fast
    // regression.
    const main = page.locator("main");
    await main.waitFor({ state: "visible" });
    const text = await main.innerText().catch(() => "");

    for (const needle of tab.expect) {
      check(
        text.includes(needle),
        `${tab.name} tab did not render ${JSON.stringify(needle)}. This is what an ` +
          `empty page looks like from CI. First 300 chars: ${JSON.stringify(text.slice(0, 300))}`,
      );
    }

    // "Data unavailable" is how every one of the findings above presented. In
    // LOCAL_DATA mode every provider is a committed fixture, so there is no
    // upstream to be unavailable - seeing it means the app itself failed.
    check(
      !text.includes("Data unavailable"),
      `${tab.name} tab rendered "Data unavailable" in LOCAL_DATA mode, where every ` +
        `provider is a committed fixture and nothing can be upstream-unavailable. ` +
        `The failure is in the app, not the estate.`,
    );
  }

  // F111 IN ONE ASSERTION. Ajv's runtime compile is `new Function`, which this
  // CSP forbids; the renderer caught the throw and reported every spec invalid.
  // A CSP violation surfaces as a console error, so an empty list here is the
  // evidence that the precompiled validator is genuinely being used.
  const cspErrors = consoleErrors.filter((e) => /Content Security Policy|unsafe-eval/i.test(e));
  check(
    cspErrors.length === 0,
    `The page violated its own Content-Security-Policy: ${JSON.stringify(cspErrors)}. ` +
      `This is F111's shape - something is evaluating generated code at runtime.`,
  );

  check(
    consoleErrors.length === 0,
    `Console errors while rendering: ${JSON.stringify(consoleErrors.slice(0, 5))}`,
  );
} finally {
  await browser.close();
  server.close();
}

if (failures.length > 0) {
  console.error("\nBROWSER RENDER CHECK FAILED\n");
  for (const f of failures) console.error(`  - ${f}\n`);
  process.exit(1);
}
console.log(
  `browser render check: ${TABS.length} tabs rendered under the production CSP ` +
    `with no console errors.`,
);
