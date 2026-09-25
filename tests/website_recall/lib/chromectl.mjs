// Headless Chrome control for the website-recall harness (Chrome DevTools Protocol).
//
//   node chromectl.mjs launch            start headless Chrome (own temp profile) -> $UW_CHROME_STATE
//   node chromectl.mjs nav URL           load URL (replay from store, or live), wait until settled
//   node chromectl.mjs evalfile PATH     run a JS file in the page, print the result like osascript
//   node chromectl.mjs eval 'JS'         same for an inline expression
//   node chromectl.mjs url               print the current page URL
//   node chromectl.mjs kill              stop Chrome and remove the temp profile
//
// UW_NET=replay (default): Chrome is started behind a black-hole proxy and every request is
// answered from the replay store (UW_STORE). The main document is the rendered-DOM snapshot
// (scripts disabled via CSP, so the page looks the way it did when recorded); everything else
// is blocked. UW_NET=record/live: real network; record also snapshots the rendered DOM.
// Never used with Alex's real Chrome: it always launches its own --user-data-dir.
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

const CHROME = process.env.UW_CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const STATE = process.env.UW_CHROME_STATE || '/tmp/uw_chrome';
const NET = process.env.UW_NET || 'replay';
const STORE = process.env.UW_STORE || '';
const TRACE = process.env.UW_TRACE || '';
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------- store (mirror of lib/store.py) ----------
function splitUrl(u) {
  const m = /^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\/([^/?#]*)([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/.exec((u || '').trim());
  if (!m) return null;
  return { scheme: m[1].toLowerCase(), netloc: m[2].toLowerCase(), path: m[3] || '', query: m[4] || '' };
}
function joinUrl(p) { return `${p.scheme}://${p.netloc}${p.path}${p.query ? '?' + p.query : ''}`; }
export function normUrl(u) {
  const p = splitUrl(u); if (!p) return (u || '').trim();
  let pth = p.path || '/';
  if (pth.length > 1) pth = pth.replace(/\/+$/, '') || '/';
  return joinUrl({ ...p, path: pth });
}
function variants(u) {
  const n = normUrl(u); const p = splitUrl(n); if (!p) return [n];
  const bare = p.netloc.startsWith('www.') ? p.netloc.slice(4) : p.netloc;
  const out = [n];
  for (const s of ['https', 'http']) for (const h of [p.netloc, bare, 'www.' + bare]) {
    const v = joinUrl({ scheme: s, netloc: h, path: p.path, query: p.query });
    if (!out.includes(v)) out.push(v);
  }
  return out;
}
const keyOf = (kind, u) => crypto.createHash('sha1').update(kind + '|' + normUrl(u)).digest('hex');
export function storeGet(kind, u, fallback = []) {
  if (!STORE) return null;
  const vs = variants(u);
  for (let i = 0; i < vs.length; i++) {
    const kinds = [kind, ...fallback];
    for (let j = 0; j < kinds.length; j++) {
      const mp = path.join(STORE, 'entries', keyOf(kinds[j], vs[i]) + '.json');
      if (!fs.existsSync(mp)) continue;
      try {
        const meta = JSON.parse(fs.readFileSync(mp, 'utf8'));
        const body = meta.body ? zlib.gunzipSync(fs.readFileSync(path.join(STORE, meta.body))) : Buffer.alloc(0);
        return { meta, body, approx: i > 0 || j > 0 };
      } catch { /* try next */ }
    }
  }
  return null;
}
export function storePut(kind, u, finalUrl, status, ctype, body, extra = {}) {
  if (!STORE) return;
  fs.mkdirSync(path.join(STORE, 'entries'), { recursive: true });
  fs.mkdirSync(path.join(STORE, 'bodies'), { recursive: true });
  const k = keyOf(kind, u);
  const buf = Buffer.from(body || '');
  const rel = path.join('bodies', crypto.createHash('sha1').update(buf).digest('hex') + '.gz');
  if (!fs.existsSync(path.join(STORE, rel))) {
    const tmp = path.join(STORE, rel + '.tmp' + process.pid);
    fs.writeFileSync(tmp, zlib.gzipSync(buf, { level: 6 }));
    fs.renameSync(tmp, path.join(STORE, rel));
  }
  const meta = { url: u, final_url: finalUrl || u, status: status | 0, ctype: ctype || '', kind,
    fetched_at: new Date().toISOString().slice(0, 19), body: rel, ...extra };
  const mp = path.join(STORE, 'entries', k + '.json');
  fs.writeFileSync(mp + '.tmp' + process.pid, JSON.stringify(meta));
  fs.renameSync(mp + '.tmp' + process.pid, mp);
}
function trace(rec) {
  if (!TRACE) return;
  rec.t = Date.now() / 1000;
  fs.appendFileSync(TRACE, JSON.stringify(rec) + '\n');
}
async function politeWait(u) {
  const gap = parseFloat(process.env.UW_MIN_GAP || '1.0') * 1000;
  const d = process.env.UW_HOSTLOCK_DIR || '/tmp/uw_hostlock';
  fs.mkdirSync(d, { recursive: true });
  const p = splitUrl(u); if (!p) return;
  const f = path.join(d, p.netloc.replace(/^www\./, '') || 'x');
  let last = 0; try { last = parseFloat(fs.readFileSync(f, 'utf8')) * 1000 || 0; } catch { }
  const wait = last + gap - Date.now();
  if (wait > 0) await sleep(wait);
  try { fs.writeFileSync(f, String(Date.now() / 1000)); } catch { }
}

// ---------- CDP plumbing ----------
function readState() {
  try { return JSON.parse(fs.readFileSync(path.join(STATE, 'state.json'), 'utf8')); } catch { return null; }
}
function writeState(s) { fs.mkdirSync(STATE, { recursive: true }); fs.writeFileSync(path.join(STATE, 'state.json'), JSON.stringify(s)); }

async function connect() {
  const st = readState();
  if (!st) throw new Error('chrome not launched');
  let targets;
  for (let i = 0; i < 50; i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${st.port}/json`)).json(); break; } catch { await sleep(100); }
  }
  let page = targets && targets.find(t => t.type === 'page');
  if (!page) {
    page = await (await fetch(`http://127.0.0.1:${st.port}/json/new?about:blank`, { method: 'PUT' })).json();
  }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0; const pending = new Map(); const handlers = [];
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(m.error) : p.res(m.result); return; }
    for (const h of handlers) { try { h(m); } catch (e) { } }
  };
  const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
  return { send, on: h => handlers.push(h), close: () => { try { ws.close(); } catch { } }, st };
}

async function launch() {
  const old = readState();
  if (old && old.pid) { try { process.kill(old.pid, 0); return old; } catch { } }
  fs.mkdirSync(STATE, { recursive: true });
  const port = 9500 + Math.floor(Math.random() * 400);
  let ver = '124.0.0.0';
  try { ver = (execFileSync(CHROME, ['--version']).toString().match(/(\d+\.\d+\.\d+\.\d+)/) || [])[1] || ver; } catch { }
  const ua = `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${ver} Safari/537.36`;
  const args = ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${path.join(STATE, 'profile')}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync', '--mute-audio',
    '--disable-background-networking', '--disable-component-update', '--window-size=1366,900', `--user-agent=${ua}`];
  if (NET === 'replay') args.push('--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>');
  args.push('about:blank');
  const child = spawn(CHROME, args, { stdio: 'ignore', detached: true });
  child.unref();
  const st = { port, pid: child.pid, net: NET, current_url: 'about:blank' };
  writeState(st);
  for (let i = 0; i < 100; i++) { try { await fetch(`http://127.0.0.1:${port}/json/version`); return st; } catch { await sleep(100); } }
  throw new Error('chrome did not start');
}

async function nav(url) {
  const c = await connect();
  const { send } = c;
  await send('Page.enable');
  await send('Page.setLifecycleEventsEnabled', { enabled: true });
  const tree = await send('Page.getFrameTree');
  const mainFrame = tree.frameTree.frame.id;
  let loaded = false, idle = false, docStatus = 0, docUrl = url, missing = false, approx = false, served = '';
  c.on(m => {
    if (m.method === 'Page.loadEventFired') loaded = true;
    if (m.method === 'Page.lifecycleEvent' && m.params.frameId === mainFrame && m.params.name === 'networkAlmostIdle') idle = true;
    if (m.method === 'Network.responseReceived' && m.params.type === 'Document' && m.params.frameId === mainFrame) {
      docStatus = m.params.response.status; docUrl = m.params.response.url;
    }
  });
  // record mode serves pages it already has (never overwrite a good snapshot with a later 403);
  // only a page missing from the store goes to the network.
  const haveGood = () => { const h = storeGet('chrome', url); return h && h.meta.status >= 200 && h.meta.status < 400; };
  const serveStored = NET === 'replay' || (NET === 'record' && haveGood());
  if (serveStored) {
    const aliases = new Map();
    await send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }] });
    c.on(async m => {
      if (m.method !== 'Fetch.requestPaused') return;
      const { requestId, request, resourceType, frameId } = m.params;
      try {
        if (resourceType === 'Document' && frameId === mainFrame) {
          let hit = aliases.get(normUrl(request.url)) || storeGet('chrome', request.url);
          let scriptsOff = true;
          if (!hit) { hit = storeGet('curl', request.url, ['req']); if (hit) { approx = true; served = 'raw'; } }
          else if (!served) served = hit.meta.kind === 'chrome' ? 'rendered' : 'raw';
          if (hit && hit.approx) approx = true;
          if (!hit) {
            missing = true;
            await send('Fetch.fulfillRequest', { requestId, responseCode: 404, responseHeaders: [{ name: 'Content-Type', value: 'text/html' }], body: Buffer.from('<html><body>not captured</body></html>').toString('base64') });
            return;
          }
          const fin = hit.meta.final_url || request.url;
          if (normUrl(fin) !== normUrl(request.url) && !aliases.has(normUrl(fin))) {
            aliases.set(normUrl(fin), hit);
            await send('Fetch.fulfillRequest', { requestId, responseCode: 302, responseHeaders: [{ name: 'Location', value: fin }], body: '' });
            return;
          }
          const status = hit.meta.kind === 'chrome' ? (hit.meta.status || 200) : (hit.meta.status || 200);
          const headers = [{ name: 'Content-Type', value: hit.meta.kind === 'chrome' ? 'text/html; charset=utf-8' : (hit.meta.ctype || 'text/html') }];
          if (scriptsOff) headers.push({ name: 'Content-Security-Policy', value: "script-src 'none'; frame-src 'none'" });
          await send('Fetch.fulfillRequest', { requestId, responseCode: status || 200, responseHeaders: headers, body: hit.body.toString('base64') });
        } else {
          await send('Fetch.failRequest', { requestId, errorReason: 'BlockedByClient' });
        }
      } catch (e) { try { await send('Fetch.failRequest', { requestId, errorReason: 'Failed' }); } catch { } }
    });
  } else {
    await politeWait(url);
    await send('Network.enable');
  }
  let prevHref = '';
  try { prevHref = (await send('Runtime.evaluate', { expression: 'location.href', returnByValue: true })).result.value || ''; } catch { }
  const t0 = Date.now();
  try { await send('Page.navigate', { url }); } catch (e) { }
  const maxWait = serveStored ? 20000 : parseInt(process.env.UW_NAV_TIMEOUT_MS || '20000', 10);
  let polls = 0;
  while (Date.now() - t0 < maxWait) {
    if (loaded && (idle || serveStored)) break;
    await sleep(100);
    // Under heavy load the load event can be late: also accept a finished document at the new URL.
    if (serveStored && ++polls % 5 === 0) {
      try {
        const r = await send('Runtime.evaluate', { expression: 'document.readyState + "|" + location.href', returnByValue: true });
        const [rs, href] = String(r.result.value || '').split('|');
        if (rs === 'complete' && href && href !== 'about:blank' && href !== prevHref) break;
      } catch { }
    }
  }
  if (!serveStored) await sleep(parseInt(process.env.UW_SETTLE_MS || '1500', 10));
  let href = url;
  try { href = (await send('Runtime.evaluate', { expression: 'location.href', returnByValue: true })).result.value || url; } catch { }
  if (!serveStored && (NET === 'record' || NET === 'live')) {
    try {
      const html = (await send('Runtime.evaluate', { expression: 'document.documentElement ? document.documentElement.outerHTML : ""', returnByValue: true })).result.value || '';
      const ft = await send('Page.getFrameTree');
      const frames = [];
      const walk = n => { for (const ch of (n.childFrames || [])) { frames.push(ch.frame.url); walk(ch); } };
      walk(ft.frameTree);
      storePut('chrome', url, href, docStatus || (loaded ? 200 : 0), 'text/html', html, { frames: frames.slice(0, 50), loaded });
      served = 'net';
    } catch (e) { }
  }
  trace({ via: 'chrome', url, final_url: href, found: !missing, source: missing ? 'missing' : (served || 'net'), approx, status: docStatus });
  const st = readState(); st.current_url = href; writeState(st);
  c.close();
  return href;
}

async function evaluate(code) {
  const c = await connect();
  try {
    const r = await c.send('Runtime.evaluate', { expression: code, returnByValue: true, timeout: 20000 });
    if (r.exceptionDetails) {
      const msg = (r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text;
      trace({ via: 'chrome-eval', error: String(msg).slice(0, 400), url: readState().current_url });
      process.stderr.write('JS exception: ' + String(msg).slice(0, 400) + '\n');
      return null; // osascript prints nothing useful when the script throws
    }
    const v = r.result.value;
    trace({ via: 'chrome-eval', ok: true, url: readState().current_url, bytes: typeof v === 'string' ? v.length : 0 });
    if (v === undefined || v === null) return 'missing value';
    return typeof v === 'string' ? v : (typeof v === 'object' ? JSON.stringify(v) : String(v));
  } finally { c.close(); }
}

async function main() {
  const [cmd, arg] = process.argv.slice(2);
  if (cmd === 'launch') { const st = await launch(); console.log(st.port); return; }
  if (cmd === 'kill') {
    const st = readState();
    if (st && st.pid) { try { process.kill(st.pid); } catch { } await sleep(300); try { process.kill(st.pid, 'SIGKILL'); } catch { } }
    try { fs.rmSync(path.join(STATE, 'profile'), { recursive: true, force: true }); } catch { }
    try { fs.rmSync(path.join(STATE, 'state.json'), { force: true }); } catch { }
    return;
  }
  if (cmd === 'nav') { await nav(arg); return; }
  if (cmd === 'url') { const st = readState(); console.log(st ? st.current_url : ''); return; }
  if (cmd === 'evalfile' || cmd === 'eval') {
    const code = cmd === 'evalfile' ? fs.readFileSync(arg, 'utf8') : arg;
    const out = await evaluate(code);
    if (out !== null) process.stdout.write(out + '\n');
    return;
  }
  console.error('usage: chromectl.mjs launch|nav URL|evalfile PATH|eval JS|url|kill'); process.exit(2);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(e => { process.stderr.write('chromectl: ' + (e && e.message || e) + '\n'); process.exit(1); });
}
