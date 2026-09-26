// loopwatch catalog UI — external file so the catalog can run under a strict CSP (script-src 'self').
(async function () {
  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g,
    (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));

  let manifest;
  try {
    const res = await fetch("manifest.json?t=" + Date.now());
    if (!res.ok) throw new Error(res.status);
    manifest = await res.json();
  } catch (e) {
    $("#tree").innerHTML = '<div class="empty">Could not load manifest.json — serve this directory over HTTP.</div>';
    return;
  }

  document.title = manifest.site_title || "Catalog";
  $("#title").textContent = manifest.site_title || "Catalog";
  if (manifest.updated) $("#updated").textContent = "updated " + manifest.updated.slice(0, 10);

  const entries = (manifest.entries || []).slice()
    .sort((a, b) => (b.date || "").localeCompare(a.date || ""));
  const digests = manifest.digests || [];

  // ── digests ──
  if (digests.length) {
    $("#digest-section").hidden = false;
    $("#digests").innerHTML = digests.slice(0, 10).map((d) =>
      `<div class="dg">
         <span class="d"><a href="${esc(d.path)}">${esc(d.date)}</a></span>
         <span class="n">${d.pages} page${d.pages === 1 ? "" : "s"}</span>
         <span class="s">${esc(d.summary)}</span>
       </div>`).join("");
  }

  // ── tree ──
  const entryHtml = (e, withCat) =>
    `<li class="entry">
       <div class="row">
         <a href="${esc(e.path)}">${esc(e.title)}</a>
         ${withCat ? `<span class="cat">${esc(e.category)}</span>` : ""}
         <span class="date">${esc(e.date)}</span>
       </div>
       <div class="sum">${esc(e.summary)}</div>
     </li>`;

  function buildTree() {
    if (!entries.length) {
      $("#tree").innerHTML = '<div class="empty">Catalog is empty — the first loopwatch run will populate it.</div>';
      return;
    }
    $("#controls").hidden = false;
    const roots = {};
    for (const e of entries) {
      const [top, sub] = (e.category || "misc").split("/");
      roots[top] = roots[top] || { direct: [], subs: {} };
      if (sub) (roots[top].subs[sub] = roots[top].subs[sub] || []).push(e);
      else roots[top].direct.push(e);
    }
    const listHtml = (arr, withCat) => `<ul class="entries">${arr.map((e) => entryHtml(e, withCat)).join("")}</ul>`;
    $("#tree").innerHTML = Object.keys(roots).sort().map((top) => {
      const r = roots[top];
      const total = r.direct.length + Object.values(r.subs).reduce((n, a) => n + a.length, 0);
      const subs = Object.keys(r.subs).sort().map((sub) =>
        `<details><summary>${esc(sub)}<span class="count">${r.subs[sub].length}</span></summary>
           ${listHtml(r.subs[sub], false)}</details>`).join("");
      return `<details><summary>${esc(top)}<span class="count">${total}</span></summary>
                ${subs}${r.direct.length ? listHtml(r.direct, false) : ""}</details>`;
    }).join("");
  }
  buildTree();

  $("#expand").onclick = () => document.querySelectorAll("#tree details").forEach((d) => (d.open = true));
  $("#collapse").onclick = () => document.querySelectorAll("#tree details").forEach((d) => (d.open = false));

  // ── search ──
  const search = $("#search");
  function runSearch() {
    const q = search.value.trim().toLowerCase();
    const showTree = q === "";
    $("#tree").hidden = !showTree;
    $("#controls").hidden = !showTree || !entries.length;
    $("#results").hidden = showTree;
    if (showTree) return;
    const hits = entries.filter((e) =>
      [e.title, e.summary, e.category, ...(e.tags || [])]
        .join(" ").toLowerCase().includes(q));
    $("#results").innerHTML = hits.length
      ? `<ul class="entries">${hits.map((e) => entryHtml(e, true)).join("")}</ul>`
      : '<div class="empty">No matches.</div>';
  }
  search.addEventListener("input", runSearch);
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "/" && document.activeElement !== search) { ev.preventDefault(); search.focus(); }
    if (ev.key === "Escape") { search.value = ""; runSearch(); search.blur(); }
  });
})();
