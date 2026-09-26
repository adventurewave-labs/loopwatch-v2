// Browser oracle: loads each rendered page in headless Chromium and reports whether it is
// ACTIVE — ran script, made any network request, or navigated — after exercising it
// (hover/focus/click every element, toggle details/popovers, wait for timers).
// usage: node oracle.cjs <dir-of-html-files>  ->  JSON {file: reason|null} on stdout
const { chromium } = require('playwright');   // resolved via NODE_PATH (global install) or local node_modules
const fs = require('node:fs');
const path = require('node:path');

(async () => {

const dir = process.argv[2];
const files = fs.readdirSync(dir).filter(f => f.endsWith('.html')).sort();
const browser = await chromium.launch({
});
const ctx = await browser.newContext({ javaScriptEnabled: true });
await ctx.addInitScript(() => {
  const hit = (why) => { try { window.__lw_active = window.__lw_active || why; } catch (e) {} };
  for (const f of ['alert', 'confirm', 'prompt', 'print', 'msgbox']) {
    try { Object.defineProperty(window, f, { value: () => hit('script:' + f), configurable: false }); } catch (e) {}
  }
});
const result = {};
async function one(f) {
  const abs = path.resolve(dir, f);
  const url = 'file://' + abs;
  const page = await ctx.newPage();
  let reason = null;
  await page.route('**/*', (route) => {
    const u = route.request().url();
    if (u === url) return route.continue();
    reason = reason || ('network:' + u.slice(0, 80));
    return route.abort();
  });
  page.on('framenavigated', (fr) => { if (fr.url().split('#')[0] !== url && fr.url() !== 'about:blank' && !fr.url().startsWith('about:srcdoc')) reason = reason || ('navigate:' + fr.url().slice(0, 80)); });
  page.on('popup', () => { reason = reason || 'popup'; });
  try {
    await page.goto(url, { waitUntil: 'load', timeout: 5000 });
    await page.evaluate(async () => {
      for (const el of Array.from(document.querySelectorAll('*'))) {
        for (const t of ['mouseover', 'mouseenter', 'focus', 'focusin', 'animationstart', 'toggle', 'beforetoggle', 'begin']) {
          try { el.dispatchEvent(new Event(t, { bubbles: true })); } catch (e) {}
        }
        try { if (el.tagName === 'DETAILS') el.open = true; } catch (e) {}
        try { el.focus && el.focus(); } catch (e) {}
      }
      for (const el of Array.from(document.querySelectorAll('a,button,area,input,summary,div,p,span,img'))) {
        try { el.click(); } catch (e) {}
      }
      await new Promise(r => setTimeout(r, 120));
    }).catch(() => {});
    await page.waitForTimeout(60);
    const active = await page.evaluate(() => window.__lw_active || null).catch(() => null);
    reason = reason || active;
  } catch (e) {
    reason = reason || ('load-error:' + String(e.message).slice(0, 60));
  }
  result[f] = reason;
  await page.close();
}
const queue = files.slice();
await Promise.all(Array.from({ length: 8 }, async () => { while (queue.length) await one(queue.shift()); }));
await browser.close();
process.stdout.write(JSON.stringify(result));
})().catch((e) => { console.error(e); process.exit(2); });
