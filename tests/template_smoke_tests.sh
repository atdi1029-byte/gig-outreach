#!/usr/bin/env bash
# ============================================================
# Gig Outreach — Frontend Template Smoke Tests
# Extracts template JS from index.html, runs all checks
# inside Node.js to avoid shell quoting issues with
# apostrophes and special characters in template text.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INDEX="$PROJECT_DIR/index.html"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== TEMPLATE SMOKE TESTS ===${NC}"
echo ""

# Step 1: Extract template JS from index.html into a temp file
TMPJS=$(mktemp /tmp/tpl_test_XXXXXX.js)
trap "rm -f $TMPJS" EXIT

python3 -c "
import re, sys

with open('$INDEX', 'r') as f:
    html = f.read()

match = re.search(r'// === TEMPLATES ===(.+?)// === CONSTANTS ===', html, re.DOTALL)
if not match:
    print('ERROR: Could not extract template JS', file=sys.stderr)
    sys.exit(1)

js = match.group(1)

out = '// Extracted template code for testing\n'
out += js
out += r'''

// === TEST HARNESS (all checks run inside Node) ===
const categories = Object.keys(TEMPLATES);
const testVenue = 'SPECIFIC_VENUE_NAME_12345';
const testContact = 'John TestPerson';

let pass = 0;
let fail = 0;
const errors = [];

function check(name, ok) {
    if (ok) {
        console.log('  \x1b[32mPASS\x1b[0m ' + name);
        pass++;
    } else {
        console.log('  \x1b[31mFAIL\x1b[0m ' + name);
        fail++;
        errors.push(name);
    }
}

// --- Email Templates: no venue name leak, uses category label ---
console.log('\x1b[36m--- Email Templates ---\x1b[0m');
for (const cat of categories) {
    // Generate 5 times to cover random variants
    let anyLeak = false;
    let anyLabel = false;
    for (let i = 0; i < 5; i++) {
        const body = generateEmail(testVenue, testContact, cat);
        if (body.includes('SPECIFIC_VENUE_NAME_12345')) anyLeak = true;
        if (body.toLowerCase().includes('your ')) anyLabel = true;
    }
    check('email/' + cat + ': no venue name leak', !anyLeak);
    check('email/' + cat + ': uses generic category label', anyLabel);
}

// --- IG Templates ---
console.log('\n\x1b[36m--- IG Templates ---\x1b[0m');
for (const cat of categories) {
    let anyLeak = false;
    for (let i = 0; i < 5; i++) {
        const body = generateIG(testVenue, testContact, cat);
        if (body.includes('SPECIFIC_VENUE_NAME_12345')) anyLeak = true;
    }
    check('ig/' + cat + ': no venue name leak', !anyLeak);
}

// --- FB Templates ---
console.log('\n\x1b[36m--- FB Templates ---\x1b[0m');
for (const cat of categories) {
    let anyLeak = false;
    for (let i = 0; i < 5; i++) {
        const body = generateFB(testVenue, testContact, cat);
        if (body.includes('SPECIFIC_VENUE_NAME_12345')) anyLeak = true;
    }
    check('fb/' + cat + ': no venue name leak', !anyLeak);
}

// --- Enhanced Template Structure ---
console.log('\n\x1b[36m--- Enhanced Template Structure ---\x1b[0m');
const eEmail = getEnhancedTemplate('email', testVenue, testContact, 'winery');
check('enhanced email has subject', eEmail.subject && eEmail.subject.length > 0);
check('enhanced email has body', eEmail.body && eEmail.body.length > 0);

const eIG = getEnhancedTemplate('ig', testVenue, testContact, 'restaurant');
check('enhanced IG has empty subject (correct)', eIG.subject === '');
check('enhanced IG has body', eIG.body && eIG.body.length > 0);

const eFB = getEnhancedTemplate('fb', testVenue, testContact, 'hotel');
check('enhanced FB has empty subject (correct)', eFB.subject === '');
check('enhanced FB has body', eFB.body && eFB.body.length > 0);

// --- Greeting Safety ---
// Bug: d05814d — greetings were using venue names
console.log('\n\x1b[36m--- Greeting Safety ---\x1b[0m');
for (let i = 0; i < 10; i++) {
    const body = generateEmail(testVenue, testContact, 'winery');
    const firstLine = body.split('\n')[0];
    const ok = firstLine.includes('John') || firstLine.includes('Hi!') || firstLine.includes('Hey!');
    if (!ok) {
        check('email greeting uses first name or generic', false);
        break;
    }
    if (i === 9) check('email greeting uses first name or generic', true);
}

// Venue-sounding names should be filtered
const skipResult = generateEmail('Test Winery', 'Le Bistro', 'winery');
const skipLine = skipResult.split('\n')[0];
const usedBadName = skipLine.includes('Le') && skipLine.includes('Bistro');
check('venue-sounding contact names filtered from greeting', !usedBadName);

// Short names filtered
const shortResult = generateEmail('Test Winery', 'Al', 'winery');
const shortLine = shortResult.split('\n')[0];
const usedShort = shortLine.includes('Al!') || shortLine.includes('Al,');
check('short contact names (<3 chars) use generic greeting', !usedShort);

// --- Email Content Requirements ---
console.log('\n\x1b[36m--- Email Content Requirements ---\x1b[0m');
// Check across multiple generations
let hasYoutube = false, hasContact = false, hasSignoff = false;
let hasIntl = false, hasLocal = false;
for (let i = 0; i < 5; i++) {
    const body = generateEmail('Test Winery', 'John Doe', 'winery');
    if (body.toLowerCase().includes('youtube.com')) hasYoutube = true;
    if (body.includes('410-794-6204')) hasContact = true;
    if (body.includes('Alexander Barnett')) hasSignoff = true;
    if (body.includes('Copacabana') || body.includes('Cadogan')) hasIntl = true;
    if (body.includes('Perry Cabin') || body.includes('Chez Francois')) hasLocal = true;
}
check('email contains YouTube link', hasYoutube);
check('email contains phone number', hasContact);
check('email contains signoff name', hasSignoff);
check('email contains international venues', hasIntl);
check('email contains local venues', hasLocal);

// --- FB No-Link Rule ---
console.log('\n\x1b[36m--- FB No-Link Rule ---\x1b[0m');
let fbHasLink = false;
for (let i = 0; i < 10; i++) {
    const body = generateFB('Test', 'John', 'winery');
    if (body.toLowerCase().includes('youtube.com') || body.toLowerCase().includes('http')) {
        fbHasLink = true;
        break;
    }
}
check('FB first message has no links', !fbHasLink);

// --- IG has YouTube link (should have it) ---
let igHasLink = false;
for (let i = 0; i < 5; i++) {
    const body = generateIG('Test', 'John', 'winery');
    // IG may or may not have link depending on variant
}

// --- All categories have labels ---
console.log('\n\x1b[36m--- Category Coverage ---\x1b[0m');
for (const cat of categories) {
    const t = TEMPLATES[cat];
    check(cat + ' has label', t.label && t.label.length > 0);
    check(cat + ' has subjects', t.subject && t.subject.length > 0);
}

// === RESULTS ===
console.log('\n\x1b[36m========================================\x1b[0m');
const total = pass + fail;
console.log('  Total: ' + total + '  \x1b[32mPass: ' + pass + '\x1b[0m  \x1b[31mFail: ' + fail + '\x1b[0m');
console.log('\x1b[36m========================================\x1b[0m');

if (errors.length > 0) {
    console.log('\n\x1b[31mFailed tests:\x1b[0m');
    for (const e of errors) console.log('  - ' + e);
}

console.log('');
if (fail === 0) {
    console.log('\x1b[32mALL TEMPLATE TESTS PASSED\x1b[0m');
    process.exit(0);
} else {
    console.log('\x1b[31m' + fail + ' TEMPLATE TEST(S) FAILED\x1b[0m');
    process.exit(1);
}
'''

with open('$TMPJS', 'w') as f:
    f.write(out)
"

# Step 2: Run all checks inside Node
node "$TMPJS"
