// loopwatch catalog server — static files from ./site behind HTTP Basic Auth.
// Zero dependencies (Node >= 20). Fails CLOSED: until CATALOG_USER and
// CATALOG_PASSWORD are set, every request except /healthz gets 503.
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.join(__dirname, 'site');
const PORT = Number(process.env.PORT || 8080);
const USER = process.env.CATALOG_USER || '';
const PASS = process.env.CATALOG_PASSWORD || '';

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.txt': 'text/plain; charset=utf-8',
};
const SECURITY_HEADERS = {
  'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'X-Robots-Tag': 'noindex, nofollow',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Cache-Control': 'private, no-cache',
};

function send(res, status, body, headers = {}) {
  res.writeHead(status, { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8', ...headers });
  res.end(body);
}

function sameSecret(a, b) {
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function authorized(req) {
  const h = req.headers.authorization || '';
  if (!h.startsWith('Basic ')) return false;
  const decoded = Buffer.from(h.slice(6), 'base64').toString('utf8');
  const i = decoded.indexOf(':');
  if (i < 0) return false;
  // evaluate both comparisons so timing does not reveal which one failed
  const okUser = sameSecret(decoded.slice(0, i), USER);
  const okPass = sameSecret(decoded.slice(i + 1), PASS);
  return okUser && okPass;
}

const server = http.createServer((req, res) => {
  let url;
  try { url = new URL(req.url, 'http://x'); } catch { return send(res, 400, 'bad request'); }
  if (url.pathname === '/healthz') return send(res, 200, 'ok');
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'method not allowed', { Allow: 'GET, HEAD' });
  if (!USER || !PASS) return send(res, 503, 'catalog locked: set CATALOG_USER and CATALOG_PASSWORD on the service');
  if (!authorized(req)) return send(res, 401, 'authentication required', { 'WWW-Authenticate': 'Basic realm="loopwatch catalog", charset="UTF-8"' });

  let rel;
  try { rel = decodeURIComponent(url.pathname); } catch { return send(res, 400, 'bad request'); }
  if (rel.endsWith('/')) rel += 'index.html';
  const file = path.normalize(path.join(ROOT, rel));
  if (file !== ROOT && !file.startsWith(ROOT + path.sep)) return send(res, 404, 'not found');

  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) return send(res, 404, 'not found');
    const headers = { ...SECURITY_HEADERS, 'Content-Type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Content-Length': st.size };
    if (path.basename(file) === 'manifest.json') headers['Cache-Control'] = 'no-store';
    res.writeHead(200, headers);
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(file).pipe(res);
  });
});

server.listen(PORT, () => console.log(`loopwatch catalog on :${PORT} (${USER && PASS ? 'auth configured' : 'LOCKED: credentials not set'})`));
