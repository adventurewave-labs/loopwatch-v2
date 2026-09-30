// loopwatch catalog search: ranked, prefix-aware, highlight-safe. No dependencies; runs in the
// browser (window.LoopwatchSearch) and in Node for tests (module.exports).
//
// Scoring is BM25F-style: each field is tokenized; a query term's frequency is summed across
// fields with weights (title 3, tags 2.5, category 1.5, summary 1), length-normalized per
// field (b = 0.75), and multiplied by the term's IDF over the catalog. Every entry must match
// ALL query terms (AND). The LAST query term also matches by prefix, so results appear while
// typing; a prefix hit scores 0.6 of an exact hit. Ties break by date (newest first).
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.LoopwatchSearch = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  const FIELDS = { title: 3, tags: 2.5, category: 1.5, summary: 1 };
  const K1 = 1.2, B = 0.75, PREFIX_WEIGHT = 0.6;

  function tokenize(s) {
    return String(s == null ? "" : s).toLowerCase()
      .normalize("NFKD").replace(/[̀-ͯ]/g, "")
      .split(/[^a-z0-9+#]+/).filter((t) => t.length > 0);
  }

  function fieldText(e, f) {
    return f === "tags" ? (e.tags || []).join(" ") : f === "category" ? String(e.category || "").replace(/\//g, " ") : e[f];
  }

  function buildIndex(entries) {
    const docs = entries.map((e) => {
      const tf = {}, len = {};
      for (const f of Object.keys(FIELDS)) {
        const toks = tokenize(fieldText(e, f));
        len[f] = toks.length;
        const m = (tf[f] = new Map());
        for (const t of toks) m.set(t, (m.get(t) || 0) + 1);
      }
      return { e, tf, len };
    });
    const avg = {}, df = new Map();
    for (const f of Object.keys(FIELDS)) avg[f] = docs.reduce((n, d) => n + d.len[f], 0) / Math.max(1, docs.length) || 1;
    for (const d of docs) {
      const seen = new Set();
      for (const f of Object.keys(FIELDS)) for (const t of d.tf[f].keys()) seen.add(t);
      for (const t of seen) df.set(t, (df.get(t) || 0) + 1);
    }
    return { docs, avg, df, n: docs.length, vocab: Array.from(df.keys()) };
  }

  function idf(ix, t) {
    const n = ix.df.get(t) || 0;
    return Math.log(1 + (ix.n - n + 0.5) / (n + 0.5));
  }

  // score of one query term (a set of concrete vocabulary terms with weights) against one doc
  function termScore(ix, d, variants) {
    let tfw = 0, best = 0;
    for (const [t, w] of variants) {
      let s = 0;
      for (const f of Object.keys(FIELDS)) {
        const tf = d.tf[f].get(t) || 0;
        if (!tf) continue;
        s += FIELDS[f] * tf / (1 - B + B * d.len[f] / ix.avg[f]);
      }
      if (s > 0) { tfw = Math.max(tfw, s * w); best = Math.max(best, idf(ix, t)); }
    }
    if (!tfw) return 0;
    return best * (tfw * (K1 + 1)) / (tfw + K1);
  }

  function search(ix, query, limit) {
    const q = tokenize(query);
    if (!q.length) return [];
    const variants = q.map((t, i) => {
      const v = new Map([[t, 1]]);
      if (i === q.length - 1 || t.length >= 3) {
        for (const w of ix.vocab) if (w !== t && w.startsWith(t)) v.set(w, PREFIX_WEIGHT);
      }
      return v;
    });
    const out = [];
    for (const d of ix.docs) {
      let score = 0, ok = true;
      for (const v of variants) {
        const s = termScore(ix, d, v);
        if (!s) { ok = false; break; }
        score += s;
      }
      if (ok) out.push({ entry: d.e, score, terms: variants.flatMap((v) => Array.from(v.keys())) });
    }
    out.sort((a, b) => b.score - a.score || String(b.entry.date || "").localeCompare(String(a.entry.date || "")));
    return typeof limit === "number" ? out.slice(0, limit) : out;
  }

  const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ESC[c]);

  // highlight(text, terms): HTML-escaped text with <mark> around word-prefix matches of terms.
  // Matching runs on the RAW text and every piece is escaped, so markup in text stays inert.
  function highlight(text, terms) {
    const s = String(text == null ? "" : text);
    const ts = (terms || []).filter(Boolean).map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).sort((a, b) => b.length - a.length);
    if (!ts.length) return esc(s);
    const re = new RegExp("(^|[^a-z0-9])(" + ts.join("|") + ")", "gi");
    let out = "", last = 0, m;
    while ((m = re.exec(s))) {
      const start = m.index + m[1].length, end = start + m[2].length;
      out += esc(s.slice(last, start)) + "<mark>" + esc(s.slice(start, end)) + "</mark>";
      last = end;
      if (re.lastIndex === m.index) re.lastIndex++;
    }
    return out + esc(s.slice(last));
  }

  return { tokenize, buildIndex, search, highlight, esc };
});
