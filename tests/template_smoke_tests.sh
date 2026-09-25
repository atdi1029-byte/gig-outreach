#!/usr/bin/env bash
# ============================================================
# Gig Outreach — Frontend Template Smoke Tests
# Extracts the template JS from index.html and checks EVERY template
# variant for every category inside Node (no sampling, no randomness:
# Math.random is seeded, and each body/pitch variant is forced in turn),
# so a failure is real and repeatable.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INDEX="$PROJECT_DIR/index.html"

CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== TEMPLATE SMOKE TESTS ===${NC}"
echo ""
command -v node >/dev/null 2>&1 || { echo "ERROR: node is not installed"; exit 1; }

node - "$INDEX" <<'JS'
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync(process.argv[2], 'utf8');
const m = html.match(/\/\/ === TEMPLATES ===([\s\S]+?)\/\/ === CONSTANTS ===/);
if (!m) { console.error('ERROR: Could not extract template JS'); process.exit(1); }

// Seeded PRNG so the few remaining random choices (artist order, greeting) repeat exactly.
let seed = 12345;
const ctx = { console, __rand: () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; } };
vm.createContext(ctx);
vm.runInContext('Math.random = __rand;\n' + m[1] +
  '\n;this.__t = { TEMPLATES, tplFor, generateEmail, generateIG, generateFB, getEnhancedTemplate,' +
  ' EMAIL_BODIES, IG_BODIES, FB_BODIES, IG_FOLLOWUP, YOUTUBE_LINK, CONTACT_LINE };', ctx);
const T = ctx.__t;

let pass = 0, fail = 0;
const errors = [];
function check(name, ok) {
  if (ok) { pass++; return; }
  console.log('  \x1b[31mFAIL\x1b[0m ' + name);
  fail++;
  errors.push(name);
}
function section(title, before) {
  console.log('\x1b[36m--- ' + title + ' ---\x1b[0m  (' + (pass + fail - before) + ' checks)');
}
function count(hay, needle) { return hay.split(needle).length - 1; }

// Force one variant: every pick() over this array now returns `item`.
function only(arr, item, fn) {
  const saved = arr.slice();
  arr.length = 0; arr.push(item);
  try { return fn(); } finally { arr.length = 0; saved.forEach(x => arr.push(x)); }
}

const VENUE = 'SPECIFIC_VENUE_NAME_12345';
const CONTACT = 'John TestPerson';
const PHONE = '410-794-6204';
const categories = Object.keys(T.TEMPLATES);

// --- Email: every body variant x every pitch, every category ---
let before = pass + fail;
for (const cat of categories) {
  if (cat === 'agent') continue;              // separate generator, checked below
  const t = T.tplFor(cat);
  const pitches = t.pitch.length ? t.pitch.slice() : [null];
  T.EMAIL_BODIES.forEach((bodyFn, bi) => {
    for (const pitch of pitches) {
      const body = only(T.EMAIL_BODIES, bodyFn, () =>
        pitch === null ? T.generateEmail(VENUE, CONTACT, cat) : only(t.pitch, pitch, () => T.generateEmail(VENUE, CONTACT, cat)));
      const tag = `email/${cat}/body${bi}` + (pitch ? '/pitch' : '');
      check(tag + ': no venue name leak', !body.includes(VENUE));
      // generic reference: "your <label>", or the category's own pitch when it has no label
      const generic = body.toLowerCase().includes('your ') || (t.nolabel && pitch && body.includes(pitch));
      check(tag + ': refers to the venue generically', generic);
      check(tag + ': YouTube link', body.includes(T.YOUTUBE_LINK));
      check(tag + ': phone number', body.includes(PHONE));
      check(tag + ': signed exactly once', count(body, 'Alexander Barnett') === 1);
      check(tag + ': international venues', body.includes('Copacabana') || body.includes('Cadogan'));
      check(tag + ': local venues', body.includes('Perry Cabin') || body.includes('Chez Francois'));
      const first = body.split('\n')[0];
      check(tag + ': greeting is generic or uses the first name', ['Hi!', 'Hey!'].includes(first) || first.includes('John'));
    }
  });
}
section('Email templates (every variant)', before);

// --- Agent email (own generator): seeded, 20 draws ---
before = pass + fail;
for (let i = 0; i < 20; i++) {
  const body = T.generateEmail(VENUE, CONTACT, 'agent');
  check('email/agent#' + i + ': no venue name leak', !body.includes(VENUE));
  check('email/agent#' + i + ': YouTube link + phone', body.includes(T.YOUTUBE_LINK) && body.includes(PHONE));
  check('email/agent#' + i + ': signed exactly once', count(body, 'Alexander Barnett') === 1);
}
section('Agent email', before);

// --- IG / FB first messages: every body variant, every category ---
before = pass + fail;
for (const cat of categories) {
  const t = T.tplFor(cat);
  const pitches = t.pitch.length ? t.pitch.slice() : [null];
  for (const [kind, bodies, gen] of [['ig', T.IG_BODIES, T.generateIG], ['fb', T.FB_BODIES, T.generateFB]]) {
    bodies.forEach((bodyFn, bi) => {
      for (const pitch of pitches) {
        const body = only(bodies, bodyFn, () =>
          pitch === null ? gen(VENUE, CONTACT, cat) : only(t.pitch, pitch, () => gen(VENUE, CONTACT, cat)));
        const tag = `${kind}/${cat}/body${bi}` + (pitch ? '/pitch' : '');
        check(tag + ': no venue name leak', !body.includes(VENUE));
        // bug 9351920: "Alexander Barnett" appeared twice in IG/FB messages
        check(tag + ': signed exactly once', count(body, 'Alexander Barnett') === 1);
        if (kind === 'fb') {
          // Facebook flags accounts that send links in a first message to strangers
          check(tag + ': no links', !/https?:|youtube\.com|www\./i.test(body));
        }
      }
    });
  }
}
section('IG / FB templates (every variant)', before);

// --- IG follow-up carries the playlist link (the first IG message doesn't) ---
before = pass + fail;
check('IG follow-up has the YouTube link', T.IG_FOLLOWUP.includes(T.YOUTUBE_LINK));
check('IG follow-up has the contact line', T.IG_FOLLOWUP.includes(T.CONTACT_LINE));
section('IG follow-up', before);

// --- Enhanced template structure ---
before = pass + fail;
const eEmail = T.getEnhancedTemplate('email', VENUE, CONTACT, 'winery');
check('enhanced email has subject', !!(eEmail.subject && eEmail.subject.length > 0));
check('enhanced email has body', !!(eEmail.body && eEmail.body.length > 0));
const eIG = T.getEnhancedTemplate('ig', VENUE, CONTACT, 'restaurant');
check('enhanced IG has empty subject (correct)', eIG.subject === '');
check('enhanced IG has body', !!(eIG.body && eIG.body.length > 0));
const eFB = T.getEnhancedTemplate('fb', VENUE, CONTACT, 'hotel');
check('enhanced FB has empty subject (correct)', eFB.subject === '');
check('enhanced FB has body', !!(eFB.body && eFB.body.length > 0));
for (const cat of categories) {
  for (const subj of T.TEMPLATES[cat].subject) {
    const s = only(T.TEMPLATES[cat].subject, subj, () => T.getEnhancedTemplate('email', "Joe's $1 Bar", CONTACT, cat).subject);
    check(`subject/${cat}: {venue} filled and "$" kept literally`, !s.includes('{venue}') && (!subj.includes('{venue}') || s.includes("Joe's $1 Bar")));
  }
}
section('Enhanced template structure + subjects', before);

// --- Greeting safety (bug d05814d: greeting used the venue name) ---
before = pass + fail;
const skipLine = T.generateEmail('Test Winery', 'Le Bistro', 'winery').split('\n')[0];
check('venue-sounding contact names filtered from greeting', !(skipLine.includes('Le') && skipLine.includes('Bistro')));
const shortLine = T.generateEmail('Test Winery', 'Al', 'winery').split('\n')[0];
check('short contact names (<3 chars) use generic greeting', !(shortLine.includes('Al!') || shortLine.includes('Al,')));
section('Greeting safety', before);

// --- Every category has a label and subjects ---
before = pass + fail;
for (const cat of categories) {
  const t = T.TEMPLATES[cat];
  check(cat + ' has label', !!(t.label && t.label.length > 0));
  check(cat + ' has subjects', !!(t.subject && t.subject.length > 0));
}
section('Category coverage', before);

console.log('\n\x1b[36m========================================\x1b[0m');
console.log('  Total: ' + (pass + fail) + '  \x1b[32mPass: ' + pass + '\x1b[0m  \x1b[31mFail: ' + fail + '\x1b[0m');
console.log('\x1b[36m========================================\x1b[0m');
if (errors.length) {
  console.log('\n\x1b[31mFailed tests:\x1b[0m');
  for (const e of errors) console.log('  - ' + e);
  console.log('\n\x1b[31m' + fail + ' TEMPLATE TEST(S) FAILED\x1b[0m');
  process.exit(1);
}
console.log('\n\x1b[32mALL TEMPLATE TESTS PASSED\x1b[0m');
JS
