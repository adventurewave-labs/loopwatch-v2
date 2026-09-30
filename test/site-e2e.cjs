// Browser end-to-end check of the catalog UI under the REAL catalog server and its strict CSP.
// Optional (needs Playwright + Chromium): node test/site-e2e.cjs <catalog-server.js>
// Serves site/ with a sample manifest, logs in via Basic Auth, and verifies: ranked results,
// <mark> highlights, keyboard navigation (/, arrows, Enter), no CSP violations, no XSS.
const { chromium } = require("playwright");
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");
const server = process.argv[2];
const fail = (m) => { console.error("FAIL [site-e2e]: " + m); process.exit(1); };
(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lw-site-"));
  fs.cpSync(path.join(__dirname, "..", "site"), path.join(dir, "site"), { recursive: true });
  fs.copyFileSync(server, path.join(dir, "server.js"));
  const entries = [
    { slug: "a", title: "Turbo-Flow ingest: CronJob + work queue", category: "infra/kubernetes", tags: ["k8s"], summary: "CronJob enqueues work; idempotent workers.", date: "2026-09-01", path: "pages/2026/a.html", source: "" },
    { slug: "d", title: "Watermark byte offsets", category: "debugging", tags: ["jsonl"], summary: "Mentions kubernetes once.", date: "2026-09-25", path: "pages/2026/d.html", source: "" },
    { slug: "x", title: "<img src=x onerror=window.__pwned=1> kubernetes notes", category: "security", tags: [], summary: "x", date: "2026-09-26", path: "pages/2026/x.html", source: "" },
  ];
  fs.mkdirSync(path.join(dir, "site/pages/2026"), { recursive: true });
  for (const e of entries) fs.writeFileSync(path.join(dir, "site", e.path), "<!doctype html><title>" + e.slug + "</title><p>page " + e.slug);
  fs.writeFileSync(path.join(dir, "site/manifest.json"), JSON.stringify({ version: 1, site_title: "Test catalog", updated: null, entries, digests: [] }));
  const port = 18000 + Math.floor(Math.random() * 1000);
  const srv = cp.spawn("node", [path.join(dir, "server.js")], { env: { ...process.env, PORT: String(port), CATALOG_USER: "u", CATALOG_PASSWORD: "p" }, stdio: "ignore" });
  await new Promise((r) => setTimeout(r, 600));
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ httpCredentials: { username: "u", password: "p" } });
  const page = await ctx.newPage();
  const cspErrors = [];
  page.on("console", (m) => { if (/Content Security Policy|Refused/.test(m.text())) cspErrors.push(m.text()); });
  page.on("pageerror", (e) => cspErrors.push("pageerror: " + e.message));
  try {
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle" });
    await page.keyboard.press("/");
    if (!(await page.evaluate(() => document.activeElement.id === "search"))) fail("'/' should focus search");
    await page.keyboard.type("kuber");
    await page.waitForSelector("#results .entry");
    const titles = await page.$$eval("#results .entry .row a", (as) => as.map((a) => a.textContent));
    if (titles.length !== 3) fail("expected 3 prefix matches, got " + titles.length);
    if (titles[2] !== "Watermark byte offsets") fail("summary-only mention must rank last: " + JSON.stringify(titles));
    const marks = await page.$$eval("#results mark", (ms) => ms.map((m) => m.textContent.toLowerCase()));
    if (!marks.includes("kubernetes")) fail("no <mark> highlight: " + marks);
    if (await page.evaluate(() => window.__pwned === 1 || !!document.querySelector("#results img"))) fail("title markup executed or rendered");
    await page.keyboard.press("ArrowDown");
    const act = await page.$$eval("#results .entry", (es) => es.findIndex((e) => e.classList.contains("active")));
    if (act !== 1) fail("ArrowDown should move to result 2, active=" + act);
    await Promise.all([page.waitForNavigation(), page.keyboard.press("Enter")]);
    if (!/pages\/2026\/[adx]\.html$/.test(page.url())) fail("Enter should open the active result: " + page.url());
    if (cspErrors.length) fail("CSP/page errors: " + cspErrors.join(" | "));
    console.log("PASS — site e2e (real server + CSP: ranked, highlighted, keyboard nav, no XSS, no CSP violations)");
  } finally { await browser.close(); srv.kill(); }
})().catch((e) => fail(e.stack || e));
