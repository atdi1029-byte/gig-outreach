// Level-up reveal: shows on any page, waits while the app is hidden, survives a reload.
// Runs in Chrome for Testing via the Books test lib: NODE_PATH=~/Books/tests/node_modules node tests/level_reveal_test.js
const path = require('path');
const http = require('http');
const fs = require('fs');
const { launch, newPage, check, sleep, failures } = require('/Users/alexbarnett/Books/tests/lib.js');

const ROOT = '/Users/alexbarnett/Documents/Code/Claude/Email';
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/^\/$/, '/index.html'));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  const type = p.endsWith('.html') ? 'text/html' : p.endsWith('.js') ? 'text/javascript' : 'application/octet-stream';
  res.writeHead(200, { 'Content-Type': type }); fs.createReadStream(p).pipe(res);
});

// n sent emails -> dashboard payload
const data = n => ({ venues: [], contacts: Array.from({ length: n }, (_, i) => ({ contact_id: 'c' + i, venue_id: 'v' + i, email_sent: 'true' })) });

(async () => {
  await new Promise(r => server.listen(0, r));
  const url = `http://localhost:${server.address().port}/index.html`;
  const browser = await launch();
  const page = await newPage(browser);
  // A switchable visibilityState
  await page.evaluateOnNewDocument(() => {
    window.__vis = 'visible';
    Object.defineProperty(document, 'visibilityState', { get: () => window.__vis, configurable: true });
    window.__setVis = v => { window.__vis = v; document.dispatchEvent(new Event('visibilitychange')); };
  });
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await sleep(500);

  const lvl = n => page.evaluate(n => getLevelFromEmails(n), n);
  const at = n => page.evaluate(d => { applyDashboard(d, true); }, data(n));
  const revealLevel = () => page.evaluate(() => { const r = document.querySelector('.poke-reveal'); return r ? Number(r.dataset.level) : 0; });
  const pending = () => page.evaluate(() => localStorage.getItem('outreach_level_reveal'));

  // Baseline at level 5's threshold, then go to a venue page
  const n5 = await page.evaluate(() => emailsForLevel(5));
  const n6 = await page.evaluate(() => emailsForLevel(6));
  const n7 = await page.evaluate(() => emailsForLevel(7));
  await at(n5);
  check('baseline: no reveal', (await revealLevel()) === 0);
  await page.evaluate(() => { document.querySelectorAll('.view').forEach(v => v.classList.remove('active')); document.getElementById('viewDetail').classList.add('active'); });

  // 1. Level-up while on a venue page: reveal over the page
  await page.evaluate(n => { const c = dashboardData.contacts; c.push({ contact_id: 'x', venue_id: 'y', email_sent: 'true' }); while (c.length < n) c.push({ contact_id: 'x' + c.length, venue_id: 'y', email_sent: 'true' }); renderLevelBar(); }, n6);
  check('level-up on a venue page shows the reveal', (await revealLevel()) === 6, await revealLevel());
  const onTop = await page.evaluate(() => { const r = document.querySelector('.poke-reveal'); const e = document.elementFromPoint(innerWidth / 2, innerHeight / 2); return r.contains(e); });
  check('reveal is on top of the venue page', onTop);
  check('pending saved until seen', (await pending()) === '6');

  // 2. App goes to the background before the name appears: taken down, still owed
  await sleep(800);
  await page.evaluate(() => __setVis('hidden'));
  check('hidden mid-reveal: taken down', (await revealLevel()) === 0);
  check('hidden mid-reveal: still pending', (await pending()) === '6');
  await page.evaluate(() => __setVis('visible'));
  check('back in the app: reveal replays', (await revealLevel()) === 6);

  // 3. Seen: 3s after the name shows, pending clears; overlay closes at 9s
  await sleep(1700 + 140 + 3200);
  check('seen: pending cleared', (await pending()) === null, await pending());
  check('overlay still up until tap / 9s', (await revealLevel()) === 6);
  await page.click('.poke-reveal');
  check('tap closes it', (await revealLevel()) === 0);

  // 4. Level-up while hidden: nothing shows, then shows on return
  await page.evaluate(() => __setVis('hidden'));
  await at(n7);
  check('level-up while hidden: not shown yet', (await revealLevel()) === 0);
  check('level-up while hidden: pending', (await pending()) === '7');

  // 5. App closed before seeing it: shows after the next open
  await page.evaluate(() => { window.__vis = 'visible'; });
  await page.reload({ waitUntil: 'domcontentloaded' });
  await sleep(300);
  await at(n7);
  check('after reload: owed reveal shows', (await revealLevel()) === 7, await revealLevel());
  await page.click('.poke-reveal');
  check('tap during silhouette counts as seen', (await pending()) === null);

  // 6. Same level again (refresh): no replay
  await at(n7);
  check('refresh at the same level: no replay', (await revealLevel()) === 0);

  // 7. Stale cached data (lower) then fresh: no replay of an old level
  await at(n5);
  await at(n7);
  check('stale cache then fresh: no replay', (await revealLevel()) === 0);

  await browser.cleanup();
  server.close();
  const f = failures();
  console.log(f ? `${f} FAILED` : 'ALL PASS');
  process.exit(f ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
