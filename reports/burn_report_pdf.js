// Prints the burn report's HTML page to PDF with Chrome for Testing (never the Chrome app: runs need it alone).
// usage: node reports/burn_report_pdf.js IN.html OUT.pdf
const fs = require('fs'), path = require('path'), os = require('os');
const puppeteer = require('/Users/alexbarnett/Books/tests/node_modules/puppeteer-core');
const [inp, out] = process.argv.slice(2);
const root = path.join(os.homedir(), '.cache/puppeteer/chrome');
const v = fs.readdirSync(root).filter((d) => d.startsWith('mac')).sort().pop();
const bin = path.join(root, v, fs.readdirSync(path.join(root, v))[0], 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
(async () => {
  const b = await puppeteer.launch({ executablePath: bin, headless: 'new', args: ['--no-sandbox'] });
  const pg = await b.newPage();
  await pg.goto('file://' + path.resolve(inp), { waitUntil: 'load', timeout: 120000 });
  await pg.pdf({
    path: out, format: 'Letter', printBackground: true, preferCSSPageSize: true, displayHeaderFooter: true,
    headerTemplate: '<span></span>',
    footerTemplate: '<div style="width:100%;font:7.5pt -apple-system,Helvetica,Arial,sans-serif;color:#8a94a1;padding:0 15mm;display:flex;justify-content:space-between"><span>Gig outreach: the November 2026 burn</span><span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>',
  });
  await b.close();
  console.log('wrote', out, fs.statSync(out).size, 'bytes');
})();
