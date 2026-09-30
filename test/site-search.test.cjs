// Unit tests for site/search.js (node test/site-search.test.cjs). No dependencies.
const S = require("../site/search.js");
let n = 0;
const ok = (c, m) => { n++; if (!c) { console.error("FAIL [site-search]: " + m); process.exit(1); } };
const E = [
  { slug: "a", title: "Turbo-Flow ingest: CronJob + work queue", category: "infra/kubernetes", tags: ["k8s", "cronjob"], summary: "CronJob enqueues work; idempotent workers drain it.", date: "2026-09-01" },
  { slug: "b", title: "Spot node pool with a PDB", category: "infra/kubernetes", tags: ["k8s", "spot"], summary: "Batch ingest on spot; PodDisruptionBudget of 1 prevents eviction stalls.", date: "2026-09-03" },
  { slug: "c", title: "Headless claude -p structured mode", category: "agentic/patterns", tags: ["claude-code", "cost"], summary: "Tool-free schema-constrained calls cut cost per page by 83%.", date: "2026-09-20" },
  { slug: "d", title: "Watermark byte offsets", category: "debugging", tags: ["jsonl"], summary: "Stop at the last newline; reset when the file shrank. Mentions kubernetes once.", date: "2026-09-25" },
  { slug: "e", title: "<img src=x onerror=alert(1)> escaping notes", category: "security", tags: ["xss"], summary: "Why the catalog escapes titles.", date: "2026-09-26" },
];
const ix = S.buildIndex(E);
const ids = (q) => S.search(ix, q).map((r) => r.entry.slug);

// ranking: title/category hits outrank a passing mention in a summary
ok(ids("kubernetes")[2] === "d" && ids("kubernetes").length === 3, "field weighting: summary-only mention ranks last: " + ids("kubernetes"));
// AND semantics across terms
ok(JSON.stringify(ids("spot k8s")) === '["b"]', "AND across terms: " + ids("spot k8s"));
// prefix on the term being typed
ok(ids("idempot")[0] === "a", "prefix match while typing: " + ids("idempot"));
ok(ids("struct")[0] === "c", "prefix match: " + ids("struct"));
// accents/case folding and punctuation-insensitive
ok(ids("CRONJOB")[0] === "a" && ids("cronjob,")[0] === "a", "case + punctuation folding");
// tags count
ok(ids("jsonl")[0] === "d", "tag search");
// no match -> empty; empty query -> empty
ok(ids("nonexistentterm").length === 0 && ids("   ").length === 0, "empty results");
// ties broken newest first
ok(JSON.stringify(ids("k8s")) === '["b","a"]', "newest first on equal score: " + ids("k8s"));
// highlight is XSS-safe and marks word-prefix matches
const h = S.highlight(E[4].title, ["img", "escap"]);
ok(!/<img/i.test(h) && h.includes("&lt;<mark>img</mark>") && h.includes("<mark>escap</mark>ing"), "highlight escapes markup: " + h);
ok(S.highlight("a <b>", []) === "a &lt;b&gt;", "no terms -> escaped text");
// scale: 2,000 entries index + query quickly
const big = Array.from({ length: 2000 }, (_, i) => ({ slug: "s" + i, title: "entry " + i + " about topic" + (i % 50), category: "c" + (i % 7), tags: ["t" + (i % 13)], summary: "summary text number " + i, date: "2026-01-01" }));
let t0 = Date.now(); const bix = S.buildIndex(big); const r = S.search(bix, "topic4 summ"); const ms = Date.now() - t0;
ok(r.length === 440, "big search: topic4* matches topic4 + topic40..49 (11 of 50 buckets x 40) got " + r.length);
ok(ms < 1500, "2,000-entry index+query under 1.5s (" + ms + "ms)");
console.log(`PASS — site search (${n} assertions; 2,000-entry index+query ${ms}ms)`);
