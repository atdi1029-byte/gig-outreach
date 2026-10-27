// Sent / skip / Mark Done taps: instant on screen, saved in the background, never lost.
// Runs in Chrome for Testing against a fake backend: NODE_PATH=~/Books/tests/node_modules node tests/outbox_test.js
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

// The fake sheet: writes change it, so a fresh dashboard shows what was saved
const sheet = {
  venues: [
    { venue_id: 'V1', name: 'Alpha Winery', state: 'MD', category: 'winery', status: 'pipelined', city: 'Annapolis', instagram: 'https://instagram.com/alphawinery' },
    { venue_id: 'V2', name: 'Beta Winery', state: 'MD', category: 'winery', status: 'untouched', city: 'Easton' },
  ],
  contacts: [
    { contact_id: 'C1', venue_id: 'V1', name: 'Jane Doe', title: 'Events Manager', email: 'jane@alphawinery.com', verified: 'valid', email_sent: '' },
    { contact_id: 'C2', venue_id: 'V1', name: 'Bob Roe', title: 'General Manager', email: 'bob@alphawinery.com', verified: 'valid', email_sent: '' },
    { contact_id: 'C3', venue_id: 'V1', name: 'Amy Poe', title: 'Owner', email: 'amy@alphawinery.com', verified: 'valid', email_sent: '' },
    { contact_id: 'C4', venue_id: 'V2', name: 'Tim Loe', title: 'Owner', email: 'tim@betawinery.com', verified: 'valid', email_sent: '' },
  ],
  log: [],
};
const dashboard = () => JSON.parse(JSON.stringify({ status: 'ok', venues: sheet.venues, contacts: sheet.contacts, gigs: [],
  weeklyCounts: { email: sheet.log.filter(l => l.channel === 'email').length, ig: 0, fb: 0 }, dailyCounts: { email: 0, ig: 0, fb: 0 } }));

let mode = 'ok';          // ok | fail (network error) | applied-then-fail (server writes, reply lost)
let delayMs = 0;
const requests = [];
function handle(q) {
  const a = q.action;
  if (a === 'dashboard' || !a) return dashboard();
  if (a === 'update_contact') {
    if (q.contact_id === 'C3') return { status: 'error', ambiguous: true, message: 'Ambiguous contact_id C3 (2 rows)' };
    const c = sheet.contacts.find(x => x.contact_id === q.contact_id && x.venue_id === q.venue_id);
    if (c && q.field === 'email_sent') c.email_sent = q.value;
    return { status: 'ok' };
  }
  if (a === 'log_outreach') {
    if (q.op_id && sheet.log.some(l => l.op_id === q.op_id)) return { status: 'ok', duplicate: true };
    sheet.log.push({ venue_id: q.venue_id, contact_id: q.contact_id, channel: q.channel, op_id: q.op_id });
    if (q.channel === 'instagram') sheet.venues.find(v => v.venue_id === q.venue_id).ig_dm_sent = true;
    return { status: 'ok', logged: true };
  }
  if (a === 'update_venue') {
    const v = sheet.venues.find(x => x.venue_id === q.venue_id);
    v[q.field] = q.value;
    return { status: 'ok' };
  }
  return { status: 'ok' };
}

(async () => {
  await new Promise(r => server.listen(0, r));
  const url = `http://localhost:${server.address().port}/index.html`;
  const browser = await launch();
  const page = await newPage(browser);
  await page.setRequestInterception(true);
  page.on('request', async req => {
    const u = new URL(req.url());
    if (u.hostname !== 'script.google.com') {
      if (u.hostname === 'localhost') return req.continue();
      return req.abort();
    }
    const q = Object.fromEntries(u.searchParams);
    const write = ['update_contact', 'log_outreach', 'update_venue'].includes(q.action);
    if (write) requests.push(q);
    if (write && delayMs) await sleep(delayMs);
    if (write && mode === 'fail') return req.abort();
    const out = handle(q);
    if (write && mode === 'applied-then-fail') return req.abort();
    req.respond({ status: 200, contentType: 'text/javascript', body: `${q.callback}(${JSON.stringify(out)})` });
  });

  const outbox = () => page.evaluate(() => JSON.parse(localStorage.getItem('outreach_outbox_v1') || '[]'));
  const pill = () => page.evaluate(() => { const e = document.getElementById('outboxStatus'); return e.style.display === 'none' ? '' : e.textContent; });
  const rowFor = email => page.evaluate(e => !!document.querySelector(`#detailBody .contact-wrapper[data-email="${e}"]`), email);
  const sentRows = () => page.evaluate(() => [...document.querySelectorAll('#detailBody .detail-done')].map(e => e.parentElement.textContent));
  const tap = (fn, email) => page.evaluate((fn, e) => {
    const b = document.querySelector(`#detailBody .contact-wrapper[data-email="${e}"] .btn-sent`);
    b.click();
  }, fn, email);

  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => dashboardData && dashboardData.venues.length === 2);
  await page.evaluate(() => openVenueDetail('V1'));

  // 1. Sent is instant; the two writes happen in the background
  delayMs = 1500;
  const t0 = Date.now();
  await tap('markEmailSent', 'jane@alphawinery.com');
  check('sent row gone at once', !(await rowFor('jane@alphawinery.com')), Date.now() - t0);
  check('pill shows saving', /Saving 1/.test(await pill()), await pill());
  await page.waitForFunction(() => !JSON.parse(localStorage.getItem('outreach_outbox_v1')).some(o => !o.doneAt), { timeout: 10000 });
  check('both writes went out in order', requests.map(r => r.action).join() === 'update_contact,log_outreach', requests.map(r => r.action));
  check('sheet has Jane sent', sheet.contacts[0].email_sent === 'true');
  check('pill gone when saved', (await pill()) === '');
  delayMs = 0;

  // 2. App closed before the save: the mark survives the reload and is saved on the next open
  mode = 'fail';
  await tap('markEmailSent', 'bob@alphawinery.com');
  await sleep(300);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => dashboardData && dashboardData.venues.length === 2);
  await page.evaluate(() => openVenueDetail('V1'));
  check('after reload Bob still shows as sent', !(await rowFor('bob@alphawinery.com')));
  check('after reload Bob counted as sent in data', await page.evaluate(() => dashboardData.contacts.find(c => c.contact_id === 'C2').email_sent === 'true'));
  await sleep(500);
  check('failing save shows the retry pill', /not saved yet/.test(await pill()), await pill());
  mode = 'ok';
  await page.evaluate(() => retryOutboxNow());
  await page.waitForFunction(() => !JSON.parse(localStorage.getItem('outreach_outbox_v1')).some(o => !o.doneAt), { timeout: 10000 });
  check('Bob saved after the network came back', sheet.contacts[1].email_sent === 'true');
  check('Bob logged once', sheet.log.filter(l => l.contact_id === 'C2').length === 1);

  // 3. Server wrote it but the reply was lost: the retry carries the same op_id (no double log)
  requests.length = 0;
  sheet.contacts[1].email_sent = ''; // pretend Bob's row is fresh again for a second send test
  await page.evaluate(() => { _outbox = []; saveOutbox(); });
  mode = 'applied-then-fail';
  await page.evaluate(() => { queueMark({ kind: 'fb', venueId: 'V1', steps: [{ params: { action: 'log_outreach', venue_id: 'V1', contact_id: '', channel: 'facebook' } }] }); });
  await sleep(800);
  mode = 'ok';
  await page.evaluate(() => retryOutboxNow());
  await page.waitForFunction(() => !JSON.parse(localStorage.getItem('outreach_outbox_v1')).some(o => !o.doneAt), { timeout: 10000 });
  const fbReqs = requests.filter(r => r.channel === 'facebook');
  check('retry reused the op_id', fbReqs.length >= 2 && fbReqs.every(r => r.op_id === fbReqs[0].op_id), fbReqs.map(r => r.op_id));
  check('facebook logged once', sheet.log.filter(l => l.channel === 'facebook').length === 1);

  // 4. A refusal (ambiguous contact) puts the row back and says so
  await page.evaluate(() => openVenueDetail('V1'));
  await tap('markEmailSent', 'amy@alphawinery.com');
  await page.waitForFunction(() => !!document.querySelector('#detailBody .contact-wrapper[data-email="amy@alphawinery.com"]'), { timeout: 5000 }).catch(() => {});
  check('refused send: Amy row back', await rowFor('amy@alphawinery.com'));
  check('refused send: toast says not saved', await page.evaluate(() => /Not saved/.test(document.getElementById('toast').textContent)));
  check('refused send: dropped from outbox', !(await outbox()).some(o => o.contactId === 'C3'));

  // 5. IG Sent: instant, saved, survives a fresh load
  const igBtn = await page.$('#detailBody button[onclick^="markIGSent"]');
  check('IG Sent button shown', !!igBtn);
  if (igBtn) await igBtn.evaluate(b => b.click());
  check('IG row gone at once', !(await page.$('#detailBody button[onclick^="markIGSent"]')), await outbox());

  // 6. Mark Done from a list: Back shows the list without that venue, at the same spot
  await page.evaluate(() => { history.back(); });
  await sleep(200);
  await page.evaluate(() => { openState('MD'); openCategory('winery'); });
  const before = await page.evaluate(() => document.querySelectorAll('#categoryBody .venue-list-item').length);
  await page.evaluate(() => openVenueDetail('V2'));
  await page.evaluate(() => markVenueDone('V2'));
  await sleep(300);
  const after = await page.evaluate(() => ({ view: navStack[navStack.length - 1], names: [...document.querySelectorAll('#categoryBody .venue-list-name')].map(e => e.textContent) }));
  check('Mark Done goes straight back to the list', after.view === 'viewCategory', after.view);
  check('finished venue gone from the list', before === 2 && !after.names.includes('Beta Winery'), { before, after });
  await page.waitForFunction(() => !JSON.parse(localStorage.getItem('outreach_outbox_v1')).some(o => !o.doneAt), { timeout: 10000 });
  check('Mark Done saved (dismissed: nothing sent)', sheet.venues[1].status === 'dismissed', sheet.venues[1].status);

  // 7. A dashboard fetched after the saves drops the saved marks from the outbox
  await page.evaluate(() => { history.back(); history.back(); });
  await sleep(300);
  await page.evaluate(() => { window._forceRefresh = true; loadDashboard(); });
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('outreach_outbox_v1')).length === 0, { timeout: 10000 }).catch(() => {});
  check('outbox empty after a fresh load', (await outbox()).length === 0, (await outbox()).length);
  check('fresh data keeps Jane sent', await page.evaluate(() => dashboardData.contacts.find(c => c.contact_id === 'C1').email_sent === 'true'));

  // (the service worker can't update from a test server; that's not the app)
  const errs = page.errors.filter(e => !/ServiceWorker/.test(e));
  check('no page errors', errs.length === 0, errs);
  await browser.cleanup();
  server.close();
  const f = failures();
  console.log(f ? `${f} FAILED` : 'ALL PASS');
  process.exit(f ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
