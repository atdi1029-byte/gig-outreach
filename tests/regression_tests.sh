#!/usr/bin/env bash
# ============================================================
# Gig Outreach — Regression Test Suite
# Hits the Apps Script endpoint via curl, verifies responses,
# reads back data to confirm persistence.
#
# It WRITES test venues/contacts/gigs (REGTEST_*) and deletes them again.
# By default it refuses to run against the production deployment:
#   GIG_OUTREACH_URL=<test deployment /exec URL> tests/regression_tests.sh
# To run it against production anyway (e.g. right after a deploy):
#   tests/regression_tests.sh --allow-production    (or ALLOW_PRODUCTION_TESTS=1)
# On production the monthly-task save test is skipped (it would overwrite
# Alex's real monthly tasks). The run aborts as soon as a created ID comes
# back empty, so a parse failure can't leave orphan rows behind.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
. "$PROJECT_DIR/env_check.sh" || exit 1

# --- Config ---
PROD_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
ENV_URL=""
[ -f "$PROJECT_DIR/.env" ] && ENV_URL=$(grep -E '^(export )?APPS_SCRIPT_URL=' "$PROJECT_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
ALLOW_PRODUCTION="${ALLOW_PRODUCTION_TESTS:-0}"
for arg in "$@"; do
  case "$arg" in
    --allow-production) ALLOW_PRODUCTION=1 ;;
    *) echo "Usage: GIG_OUTREACH_URL=<test /exec URL> $0   |   $0 --allow-production"; exit 2 ;;
  esac
done
BASE_URL="${GIG_OUTREACH_URL:-${ENV_URL:-$PROD_URL}}"
ON_PRODUCTION=0
if [[ "$BASE_URL" == "$PROD_URL" ]]; then
  ON_PRODUCTION=1
elif [[ -n "$ENV_URL" && "$BASE_URL" == "$ENV_URL" ]]; then
  ON_PRODUCTION=1
fi
if [[ $ON_PRODUCTION -eq 1 && "$ALLOW_PRODUCTION" != "1" ]]; then
  echo "Refusing to run: $BASE_URL is the PRODUCTION sheet."
  echo "Set GIG_OUTREACH_URL to a test deployment, or pass --allow-production to write (and then delete) REGTEST_* rows there."
  exit 2
fi
TS=$(date +%s)
TEST_PREFIX="REGTEST_${TS}"
# Contact emails must be on the test venue's own domain and must not look like
# junk (no example.com, no long digit runs in the local part).
TEST_DOMAIN="regtest-${TS}.org"
PASS=0
FAIL=0
ERRORS=()

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Helpers ---
api() {
  # api "action=foo&bar=baz" → returns JSON body
  local params="$1"
  local url="${BASE_URL}?${params}"
  # Apps Script redirects GET → follow redirects, 30s timeout
  curl -sL --max-time 30 "$url" 2>/dev/null
}

assert_json_field() {
  # assert_json_field "$json" ".field" "expected" "test name"
  local json="$1" field="$2" expected="$3" name="$4"
  local actual
  actual=$(echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = '${field}'.strip('.').split('.')
v = d
for k in keys:
    if isinstance(v, list):
        v = v[int(k)]
    else:
        v = v[k]
print(v)
" 2>/dev/null || echo "__PARSE_ERROR__")

  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}PASS${NC} $name"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $name"
    echo -e "       expected: ${expected}"
    echo -e "       actual:   ${actual}"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name: expected '$expected', got '$actual'")
  fi
}

assert_json_contains() {
  # assert_json_contains "$json" ".field" "substring" "test name"
  local json="$1" field="$2" substring="$3" name="$4"
  local actual
  actual=$(echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = '${field}'.strip('.').split('.')
v = d
for k in keys:
    if isinstance(v, list):
        v = v[int(k)]
    else:
        v = v[k]
print(v)
" 2>/dev/null || echo "__PARSE_ERROR__")

  if echo "$actual" | grep -qi "$substring"; then
    echo -e "  ${GREEN}PASS${NC} $name"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $name"
    echo -e "       expected to contain: ${substring}"
    echo -e "       actual: ${actual}"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name: '$actual' does not contain '$substring'")
  fi
}

assert_json_not_empty() {
  local json="$1" field="$2" name="$3"
  local actual
  actual=$(echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = '${field}'.strip('.').split('.')
v = d
for k in keys:
    if isinstance(v, list):
        v = v[int(k)]
    else:
        v = v[k]
print(v)
" 2>/dev/null || echo "")

  if [[ -n "$actual" && "$actual" != "None" && "$actual" != "" ]]; then
    echo -e "  ${GREEN}PASS${NC} $name"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $name"
    echo -e "       field was empty or None"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name: field '$field' was empty")
  fi
}

assert_status_ok() {
  local json="$1" name="$2"
  assert_json_field "$json" "status" "ok" "$name"
}

json_get() {
  # json_get "$json" key  -> top-level value or empty
  echo "$1" | python3 -c "import sys,json; v=json.load(sys.stdin).get(sys.argv[1], ''); print('' if v is None else v)" "$2" 2>/dev/null
}

# A created ID that comes back empty means the response wasn't parsed; stop now
# rather than writing more rows we can't clean up.
require_id() {
  local id="$1" what="$2" json="${3:-}"
  if [[ -z "$id" ]]; then
    echo -e "  ${RED}FATAL${NC} $what returned no id — aborting (response: ${json:0:200})"
    FAIL=$((FAIL + 1))
    exit 1
  fi
}

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); ERRORS+=("$1"); }

# Track test venue/contact/gig IDs for cleanup
CLEANUP_VENUE_IDS=()
CLEANUP_CONTACT_IDS=()
CLEANUP_GIG_IDS=()

cleanup() {
  echo ""
  echo -e "${CYAN}=== CLEANUP ===${NC}"
  for pair in "${CLEANUP_CONTACT_IDS[@]:-}"; do
    [[ -z "$pair" ]] && continue
    api "action=delete_contact&contact_id=${pair%%|*}&venue_id=${pair#*|}" > /dev/null 2>&1 || true
  done
  if [[ -n "${MONTHLY_RESTORE:-}" ]]; then
    echo "  Restoring monthly tasks..."
    api "$MONTHLY_RESTORE" > /dev/null 2>&1 || true
  fi
  for vid in "${CLEANUP_VENUE_IDS[@]:-}"; do
    [[ -z "$vid" ]] && continue
    echo "  Deleting test venue $vid..."
    api "action=delete_venue&venue_id=${vid}" > /dev/null 2>&1 || true
  done
  for gid in "${CLEANUP_GIG_IDS[@]:-}"; do
    [[ -z "$gid" ]] && continue
    echo "  Deleting test gig $gid..."
    api "action=delete_gig&gig_id=${gid}" > /dev/null 2>&1 || true
  done
  echo "  Cleanup complete."
}
trap cleanup EXIT

# ============================================================
# TEST GROUP 1: Health Check (with warmup retry)
# ============================================================
echo -e "${CYAN}=== 1. HEALTH CHECK ===${NC}"

# Apps Script cold starts can return HTML on first hit — retry up to 3 times
HEALTH=""
for attempt in 1 2 3; do
  HEALTH=$(api "action=")
  if echo "$HEALTH" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    break
  fi
  echo "  Warmup attempt $attempt — retrying in 3s..."
  sleep 3
done
assert_json_field "$HEALTH" "status" "ok" "API health check returns ok"
assert_json_not_empty "$HEALTH" "timestamp" "API returns timestamp"
# The C5 backend reports a version; the old one doesn't. Expectations differ.
BACKEND_VERSION=$(json_get "$HEALTH" version)
NEW_BACKEND=0
[[ -n "$BACKEND_VERSION" ]] && NEW_BACKEND=1
echo "  Backend version: ${BACKEND_VERSION:-none (pre-C5 backend)}  production: $ON_PRODUCTION"

# ============================================================
# TEST GROUP 2: Add Venue
# Bug caught: venues disappearing (912b37d), duplicate IDs
# ============================================================
echo ""
echo -e "${CYAN}=== 2. ADD VENUE ===${NC}"

VENUE_NAME="${TEST_PREFIX}_TestWinery"
ADD_VENUE=$(api "action=add_venue&name=${VENUE_NAME}&category=winery&website=https://www.${TEST_DOMAIN}&city=Annapolis&state=MD&source=regression_test&upscale_score=4&zone_priority=green")
assert_status_ok "$ADD_VENUE" "add_venue returns ok"

TEST_VENUE_ID=$(json_get "$ADD_VENUE" venue_id)
require_id "$TEST_VENUE_ID" "add_venue" "$ADD_VENUE"
CLEANUP_VENUE_IDS+=("$TEST_VENUE_ID")
echo "  Created venue: $TEST_VENUE_ID"

# Read back via venue_detail
DETAIL=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_status_ok "$DETAIL" "venue_detail returns ok"
assert_json_field "$DETAIL" "venue.name" "$VENUE_NAME" "venue name persisted correctly"
assert_json_field "$DETAIL" "venue.category" "winery" "venue category persisted"
assert_json_field "$DETAIL" "venue.city" "Annapolis" "venue city persisted"
assert_json_field "$DETAIL" "venue.state" "MD" "venue state persisted"
if [[ $NEW_BACKEND -eq 1 ]]; then
  assert_json_field "$DETAIL" "venue.status" "needs_review" "new venue starts as needs_review (P4)"
  api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=status&value=untouched" > /dev/null
else
  assert_json_field "$DETAIL" "venue.status" "untouched" "new venue starts as untouched (old backend)"
fi
assert_json_field "$DETAIL" "venue.zone_priority" "green" "venue zone_priority persisted"

# Duplicate detection (same name + city + website)
DUP=$(api "action=add_venue&name=${VENUE_NAME}&category=winery&city=Annapolis&state=MD&website=https://www.${TEST_DOMAIN}")
assert_json_contains "$DUP" "message" "Duplicate" "duplicate venue detected"
DUP_VID=$(json_get "$DUP" venue_id)
if [[ -n "$DUP_VID" && "$DUP_VID" != "$TEST_VENUE_ID" ]]; then
  CLEANUP_VENUE_IDS+=("$DUP_VID")
  fail "duplicate add_venue created a second venue ($DUP_VID)"
fi
if [[ $NEW_BACKEND -eq 1 ]]; then
  assert_json_field "$DUP" "duplicate" "True" "duplicate add_venue returns duplicate:true"
  DUPD=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
  assert_json_field "$DUPD" "venue.status" "untouched" "duplicate add_venue does not change the existing status"
fi

# ============================================================
# TEST GROUP 3: Add Contact
# Bug caught: duplicate contact_id (d3ed927), generic email
# filtering (fe06536)
# ============================================================
echo ""
echo -e "${CYAN}=== 3. ADD CONTACT ===${NC}"

JANE="jane.doe@${TEST_DOMAIN}"
ADD_CONTACT=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Jane+Doe&title=Events+Manager&email=${JANE}&source=regression_test&verified=valid")
assert_status_ok "$ADD_CONTACT" "add_contact returns ok"

TEST_CONTACT_ID=$(json_get "$ADD_CONTACT" contact_id)
require_id "$TEST_CONTACT_ID" "add_contact" "$ADD_CONTACT"
CLEANUP_CONTACT_IDS+=("${TEST_CONTACT_ID}|${TEST_VENUE_ID}")
[[ $NEW_BACKEND -eq 1 ]] && assert_json_field "$ADD_CONTACT" "created" "True" "add_contact returns created:true"
echo "  Created contact: $TEST_CONTACT_ID"

# Read back via venue_detail
DETAIL2=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL2" "contacts.0.name" "Jane Doe" "contact name persisted"
assert_json_field "$DETAIL2" "contacts.0.title" "Events Manager" "contact title persisted"
assert_json_field "$DETAIL2" "contacts.0.email" "${JANE}" "contact email persisted"
assert_json_field "$DETAIL2" "contacts.0.verified" "valid" "contact verified status persisted"
assert_json_field "$DETAIL2" "contacts.0.source" "regression_test" "contact source persisted"

# Duplicate contact detection (same email + venue)
DUP_CONTACT=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&email=${JANE}&name=Jane+Doe")
assert_json_contains "$DUP_CONTACT" "message" "Duplicate" "duplicate contact email detected"
[[ $NEW_BACKEND -eq 1 ]] && assert_json_field "$DUP_CONTACT" "duplicate" "True" "duplicate add_contact returns duplicate:true"

# Add second contact to test multi-contact venue
ADD_C2=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Bob+Smith&title=Owner&email=bob.smith@${TEST_DOMAIN}&source=regression_test&verified=valid")
TEST_CONTACT_ID2=$(json_get "$ADD_C2" contact_id)
require_id "$TEST_CONTACT_ID2" "add_contact (second)" "$ADD_C2"
CLEANUP_CONTACT_IDS+=("${TEST_CONTACT_ID2}|${TEST_VENUE_ID}")

# Verify both contacts appear
DETAIL3=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
CONTACT_COUNT=$(echo "$DETAIL3" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('contacts',[])))" 2>/dev/null)
if [[ "$CONTACT_COUNT" == "2" ]]; then
  echo -e "  ${GREEN}PASS${NC} venue has 2 contacts"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC} venue should have 2 contacts, has $CONTACT_COUNT"
  ((FAIL++))
  ERRORS+=("multi-contact: expected 2, got $CONTACT_COUNT")
fi

# ============================================================
# TEST GROUP 3b: add_contact server-side rules (C5 backend only)
# ============================================================
if [[ $NEW_BACKEND -eq 1 ]]; then
  echo ""
  echo -e "${CYAN}=== 3b. ADD CONTACT RULES (C5) ===${NC}"
  R1=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Some+One&email=someone@example.com&source=regression_test")
  assert_json_field "$R1" "status" "error" "junk/placeholder email refused"
  [[ -n "$(json_get "$R1" contact_id)" ]] && CLEANUP_CONTACT_IDS+=("$(json_get "$R1" contact_id)|${TEST_VENUE_ID}")
  R2=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Vendor+Person&email=vendor.person@other-${TEST_DOMAIN}&source=regression_test")
  assert_json_field "$R2" "status" "error" "off-domain email refused"
  [[ -n "$(json_get "$R2" contact_id)" ]] && CLEANUP_CONTACT_IDS+=("$(json_get "$R2" contact_id)|${TEST_VENUE_ID}")
  R3=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Jane+D%2A%2A%2Ae&title=Events+Manager&source=regression_test")
  assert_json_field "$R3" "status" "error" "masked (***) name refused"
  [[ -n "$(json_get "$R3" contact_id)" ]] && CLEANUP_CONTACT_IDS+=("$(json_get "$R3" contact_id)|${TEST_VENUE_ID}")
  R4=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Pending+Person&title=General+Manager&source=regression_test")
  assert_json_field "$R4" "created" "True" "email-less contact with a real name is created"
  [[ -n "$(json_get "$R4" contact_id)" ]] && CLEANUP_CONTACT_IDS+=("$(json_get "$R4" contact_id)|${TEST_VENUE_ID}")
  R5=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=pending+person&title=GM&source=regression_test")
  assert_json_field "$R5" "duplicate" "True" "email-less contact deduped on (venue, name)"
  R6=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Carl+Default&email=carl.default@${TEST_DOMAIN}&source=regression_test")
  [[ -n "$(json_get "$R6" contact_id)" ]] && CLEANUP_CONTACT_IDS+=("$(json_get "$R6" contact_id)|${TEST_VENUE_ID}")
  D6=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
  V6=$(echo "$D6" | python3 -c "import sys,json; print(next((c.get('verified','') for c in json.load(sys.stdin).get('contacts',[]) if c.get('email')==sys.argv[1]), ''))" "carl.default@${TEST_DOMAIN}" 2>/dev/null)
  [[ "$V6" == "unverified" ]] && pass "verified defaults to unverified (never valid)" || fail "verified default: expected unverified, got '$V6'"
  # remove the extra rows now so the contact counts below stay as before
  for cid in "$(json_get "$R4" contact_id)" "$(json_get "$R6" contact_id)"; do
    [[ -n "$cid" ]] && api "action=delete_contact&contact_id=${cid}&venue_id=${TEST_VENUE_ID}" > /dev/null
  done
fi

# ============================================================
# TEST GROUP 4: Update Venue Fields
# Bug caught: venue status not updating, contacted_date
# not stamped (912b37d)
# ============================================================
echo ""
echo -e "${CYAN}=== 4. UPDATE VENUE ===${NC}"

# Update vote
UPD_VOTE=$(api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=venue_vote&value=up")
assert_status_ok "$UPD_VOTE" "update_venue vote returns ok"

# Update feedback
UPD_FB=$(api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=venue_feedback&value=Great+vibe")
assert_status_ok "$UPD_FB" "update_venue feedback returns ok"

# Read back
DETAIL4=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL4" "venue.venue_vote" "up" "venue vote persisted"
assert_json_field "$DETAIL4" "venue.venue_feedback" "Great vibe" "venue feedback persisted"

# Mark as contacted — should stamp contacted_date
UPD_STATUS=$(api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=status&value=contacted")
assert_status_ok "$UPD_STATUS" "update_venue status=contacted returns ok"
DETAIL5=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL5" "venue.status" "contacted" "venue status updated to contacted"

# Reset back to untouched — should clear contacted_date
UPD_RESET=$(api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=status&value=untouched")
DETAIL6=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL6" "venue.status" "untouched" "venue status reset to untouched"

# Unknown field returns error
UPD_BAD=$(api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=nonexistent&value=test")
assert_json_field "$UPD_BAD" "status" "error" "update unknown field returns error"

# ============================================================
# TEST GROUP 5: Update Contact — Mark Email Sent
# Bug caught: skip buttons silently failing (bd32f24),
# email_sent_date not set, venue auto-contacted prematurely
# ============================================================
echo ""
echo -e "${CYAN}=== 5. MARK EMAIL SENT ===${NC}"

# Mark first contact email as sent
UPD_SENT=$(api "action=update_contact&contact_id=${TEST_CONTACT_ID}&venue_id=${TEST_VENUE_ID}&field=email_sent&value=true")
assert_status_ok "$UPD_SENT" "mark email_sent=true returns ok"

DETAIL7=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL7" "contacts.0.email_sent" "true" "email_sent persisted as true"

# Venue should NOT be auto-contacted yet (second contact unsent)
assert_json_field "$DETAIL7" "venue.status" "untouched" "venue stays untouched with unsent contacts"

# Mark second contact as sent — now venue should auto-contact
UPD_SENT2=$(api "action=update_contact&contact_id=${TEST_CONTACT_ID2}&venue_id=${TEST_VENUE_ID}&field=email_sent&value=true")
DETAIL8=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL8" "venue.status" "contacted" "venue auto-contacted when all emails sent"

# Reset for further tests
api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=status&value=untouched" > /dev/null
api "action=update_contact&contact_id=${TEST_CONTACT_ID}&venue_id=${TEST_VENUE_ID}&field=email_sent&value=false" > /dev/null
api "action=update_contact&contact_id=${TEST_CONTACT_ID2}&venue_id=${TEST_VENUE_ID}&field=email_sent&value=false" > /dev/null

# ============================================================
# TEST GROUP 6: Skip Contact
# Bug caught: skip buttons silently failing (bd32f24)
# ============================================================
echo ""
echo -e "${CYAN}=== 6. SKIP CONTACT ===${NC}"

UPD_SKIP=$(api "action=update_contact&contact_id=${TEST_CONTACT_ID}&venue_id=${TEST_VENUE_ID}&field=email_sent&value=skipped")
assert_status_ok "$UPD_SKIP" "skip contact returns ok"

DETAIL9=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL9" "contacts.0.email_sent" "skipped" "email_sent persisted as skipped"

# Reset
api "action=update_contact&contact_id=${TEST_CONTACT_ID}&venue_id=${TEST_VENUE_ID}&field=email_sent&value=false" > /dev/null

# ============================================================
# TEST GROUP 7: Log Outreach — IG/FB/Email
# Bug caught: IG/FB sent status not persisting (511f1e2)
# ============================================================
echo ""
echo -e "${CYAN}=== 7. LOG OUTREACH ===${NC}"

# Log email outreach
LOG_EMAIL=$(api "action=log_outreach&venue_id=${TEST_VENUE_ID}&contact_id=${TEST_CONTACT_ID}&channel=email&template_used=winery")
assert_status_ok "$LOG_EMAIL" "log email outreach returns ok"

# Log IG outreach
LOG_IG=$(api "action=log_outreach&venue_id=${TEST_VENUE_ID}&contact_id=&channel=instagram&template_used=winery")
assert_status_ok "$LOG_IG" "log IG outreach returns ok"

# Log FB outreach
LOG_FB=$(api "action=log_outreach&venue_id=${TEST_VENUE_ID}&contact_id=&channel=facebook&template_used=winery")
assert_status_ok "$LOG_FB" "log FB outreach returns ok"

# Log IG skip
LOG_IG_SKIP=$(api "action=log_outreach&venue_id=${TEST_VENUE_ID}&contact_id=&channel=instagram_skip&template_used=winery")
assert_status_ok "$LOG_IG_SKIP" "log IG skip outreach returns ok"

# Log FB skip
LOG_FB_SKIP=$(api "action=log_outreach&venue_id=${TEST_VENUE_ID}&contact_id=&channel=facebook_skip&template_used=winery")
assert_status_ok "$LOG_FB_SKIP" "log FB skip outreach returns ok"

# Log contact form
LOG_FORM=$(api "action=log_outreach&venue_id=${TEST_VENUE_ID}&contact_id=&channel=contact_form&template_used=winery")
assert_status_ok "$LOG_FORM" "log contact form outreach returns ok"

# Verify IG/FB/form flags on venue detail
DETAIL10=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL10" "venue.ig_dm_sent" "True" "IG sent flag persisted on venue"
assert_json_field "$DETAIL10" "venue.fb_msg_sent" "True" "FB sent flag persisted on venue"
assert_json_field "$DETAIL10" "venue.contact_form_sent" "True" "contact form sent flag persisted on venue"

# ============================================================
# TEST GROUP 8: Update Contact Email (Apollo upsert)
# Bug caught: contact_id collisions on name-matched upsert
# ============================================================
echo ""
echo -e "${CYAN}=== 8. UPDATE CONTACT EMAIL (UPSERT) ===${NC}"

# Update existing contact by name match
UPD_EMAIL=$(api "action=update_contact_email&venue_id=${TEST_VENUE_ID}&name=Jane+Doe&email=jane.updated@${TEST_DOMAIN}&verified=valid&source=apollo")
assert_status_ok "$UPD_EMAIL" "update_contact_email returns ok"

# Check it was an update (not a new contact)
UPDATED=$(echo "$UPD_EMAIL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('updated', False))" 2>/dev/null)
if [[ "$UPDATED" == "True" ]]; then
  echo -e "  ${GREEN}PASS${NC} existing contact was updated (not duplicated)"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC} expected update=True, contact may have been duplicated"
  ((FAIL++))
  ERRORS+=("upsert: expected update, got create")
fi

# Upsert a NEW contact by name (should create)
UPD_NEW=$(api "action=update_contact_email&venue_id=${TEST_VENUE_ID}&name=New+Person&email=new.person@${TEST_DOMAIN}&verified=valid&source=apollo&title=Chef")
[[ -n "$(json_get "$UPD_NEW" contact_id)" ]] && CLEANUP_CONTACT_IDS+=("$(json_get "$UPD_NEW" contact_id)|${TEST_VENUE_ID}")
assert_status_ok "$UPD_NEW" "upsert new contact returns ok"
CREATED=$(echo "$UPD_NEW" | python3 -c "import sys,json; print(json.load(sys.stdin).get('created', False))" 2>/dev/null)
if [[ "$CREATED" == "True" ]]; then
  echo -e "  ${GREEN}PASS${NC} new contact was created via upsert"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC} expected created=True for new name"
  ((FAIL++))
  ERRORS+=("upsert new: expected create")
fi

# ============================================================
# TEST GROUP 9: LinkedIn Pending Blocks Auto-Contact
# Bug caught: venues disappearing when LinkedIn pending (912b37d)
# ============================================================
echo ""
echo -e "${CYAN}=== 9. LINKEDIN PENDING ===${NC}"

# Set linkedin_pending = true
api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=linkedin_pending&value=true" > /dev/null
# Reset status
api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=status&value=untouched" > /dev/null

# Mark all contacts as sent
DETAIL_CONTACTS=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
CONTACT_IDS=$(echo "$DETAIL_CONTACTS" | python3 -c "
import sys,json
d = json.load(sys.stdin)
for c in d.get('contacts',[]):
    print(c['contact_id'])
" 2>/dev/null)
while IFS= read -r cid; do
  [[ -z "$cid" ]] && continue
  api "action=update_contact&contact_id=${cid}&venue_id=${TEST_VENUE_ID}&field=email_sent&value=true" > /dev/null
done <<< "$CONTACT_IDS"

# Venue should NOT auto-contact because linkedin_pending=true
DETAIL11=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL11" "venue.status" "untouched" "linkedin_pending blocks auto-contact"

# Clear linkedin_pending
api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=linkedin_pending&value=false" > /dev/null
api "action=update_venue&venue_id=${TEST_VENUE_ID}&field=status&value=untouched" > /dev/null

# ============================================================
# TEST GROUP 10: Delete Contact
# ============================================================
echo ""
echo -e "${CYAN}=== 10. DELETE CONTACT ===${NC}"

# Add a throwaway contact
ADD_DEL=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Delete+Me&email=delete.me@${TEST_DOMAIN}&source=test&verified=pending")
DEL_CID=$(json_get "$ADD_DEL" contact_id)
require_id "$DEL_CID" "add_contact (delete test)" "$ADD_DEL"

DEL_RESULT=$(api "action=delete_contact&contact_id=${DEL_CID}&venue_id=${TEST_VENUE_ID}")
assert_status_ok "$DEL_RESULT" "delete_contact returns ok"
assert_json_field "$DEL_RESULT" "deleted" "$DEL_CID" "deleted correct contact_id"

# Verify it's gone
DETAIL12=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
STILL_EXISTS=$(echo "$DETAIL12" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(any(c['contact_id'] == '${DEL_CID}' for c in d.get('contacts',[])))
" 2>/dev/null)
if [[ "$STILL_EXISTS" == "False" ]]; then
  echo -e "  ${GREEN}PASS${NC} deleted contact no longer in venue_detail"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC} deleted contact still appears in venue_detail"
  ((FAIL++))
  ERRORS+=("delete_contact: contact still visible after deletion")
fi

# ============================================================
# TEST GROUP 11: Delete Venue (cascade)
# ============================================================
echo ""
echo -e "${CYAN}=== 11. DELETE VENUE (CASCADE) ===${NC}"

# Create a fresh venue + contact for deletion test
ADD_V2=$(api "action=add_venue&name=${TEST_PREFIX}_DeleteMe&category=hotel&state=VA&city=Arlington&website=https://www.del-${TEST_DOMAIN}")
DEL_VID=$(json_get "$ADD_V2" venue_id)
require_id "$DEL_VID" "add_venue (cascade test)" "$ADD_V2"
CLEANUP_VENUE_IDS+=("$DEL_VID")
ADD_CC=$(api "action=add_contact&venue_id=${DEL_VID}&name=Cascade+Test&email=cascade.test@del-${TEST_DOMAIN}&verified=pending")
CASCADE_CID=$(json_get "$ADD_CC" contact_id)
require_id "$CASCADE_CID" "add_contact (cascade test)" "$ADD_CC"

DEL_V=$(api "action=delete_venue&venue_id=${DEL_VID}")
assert_status_ok "$DEL_V" "delete_venue returns ok"

# Verify venue gone
DETAIL13=$(api "action=venue_detail&venue_id=${DEL_VID}")
assert_json_field "$DETAIL13" "status" "error" "deleted venue returns error on detail lookup"

# Verify its contact went with it (a harmless update on a missing row must fail)
ORPHAN=$(api "action=update_contact&contact_id=${CASCADE_CID}&venue_id=${DEL_VID}&field=title&value=orphan-check")
if [[ "$(json_get "$ORPHAN" status)" == "error" ]]; then
  pass "delete_venue also deleted its contacts"
else
  fail "delete_venue left contact $CASCADE_CID behind"
  CLEANUP_CONTACT_IDS+=("${CASCADE_CID}|${DEL_VID}")
fi

# ============================================================
# TEST GROUP 12: Dashboard Integrity
# ============================================================
echo ""
echo -e "${CYAN}=== 12. DASHBOARD ===${NC}"

DASH=$(api "action=dashboard")
assert_status_ok "$DASH" "dashboard returns ok"
assert_json_not_empty "$DASH" "stats.totalVenues" "dashboard has totalVenues"
assert_json_not_empty "$DASH" "stats.totalContacts" "dashboard has totalContacts"
assert_json_not_empty "$DASH" "stateBreakdown" "dashboard has stateBreakdown"
assert_json_not_empty "$DASH" "categoryBreakdown" "dashboard has categoryBreakdown"

# Destructive maintenance must be a dry run unless confirm=yes (C5 backend only:
# the old backend really deletes, so never call it there)
if [[ $NEW_BACKEND -eq 1 ]]; then
  CG=$(api "action=cleanup_generic")
  assert_json_field "$CG" "dry_run" "True" "cleanup_generic without confirm=yes is a dry run"
fi

# ============================================================
# TEST GROUP 13: Templates Endpoint
# ============================================================
echo ""
echo -e "${CYAN}=== 13. TEMPLATES ===${NC}"

TMPLS=$(api "action=templates")
assert_status_ok "$TMPLS" "templates returns ok"
assert_json_not_empty "$TMPLS" "templates" "templates object not empty"

# ============================================================
# TEST GROUP 14: Stats Endpoint
# ============================================================
echo ""
echo -e "${CYAN}=== 14. STATS ===${NC}"

STATS=$(api "action=stats")
assert_status_ok "$STATS" "stats returns ok"

# ============================================================
# TEST GROUP 15: Config Endpoint
# ============================================================
echo ""
echo -e "${CYAN}=== 15. CONFIG ===${NC}"

CFG=$(api "action=config")
assert_status_ok "$CFG" "config returns ok"

# ============================================================
# TEST GROUP 16: Past Gigs — Add + Update + Read
# ============================================================
echo ""
echo -e "${CYAN}=== 16. PAST GIGS ===${NC}"

ADD_GIG=$(api "action=add_gig&venue_name=${TEST_PREFIX}_GigVenue&date=2026-01-15&category=winery&rating_tips=8&rating_rebooked=7&rating_audience=9&rating_venue_quality=8&notes=Regression+test+gig")
assert_status_ok "$ADD_GIG" "add_gig returns ok"

GIG_ID=$(echo "$ADD_GIG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('gig_id',''))" 2>/dev/null)
CLEANUP_GIG_IDS+=("$GIG_ID")
echo "  Created gig: $GIG_ID"

# Verify overall score = (8+7+9+8)/4 = 8.0
# API may return 8 or 8.0 depending on rounding — accept both
GIG_SCORE=$(echo "$ADD_GIG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('overall_score',''))" 2>/dev/null)
if [[ "$GIG_SCORE" == "8" || "$GIG_SCORE" == "8.0" ]]; then
  echo -e "  ${GREEN}PASS${NC} gig overall_score calculated correctly"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} gig overall_score calculated correctly"
  echo -e "       expected: 8 or 8.0, actual: $GIG_SCORE"
  FAIL=$((FAIL + 1))
  ERRORS+=("gig overall_score: expected 8, got $GIG_SCORE")
fi

# Update gig
UPD_GIG=$(api "action=update_gig&gig_id=${GIG_ID}&rating_tips=10&notes=Updated+by+regression")
assert_status_ok "$UPD_GIG" "update_gig returns ok"
# New overall = (10+7+9+8)/4 = 8.5
assert_json_field "$UPD_GIG" "overall_score" "8.5" "gig overall recalculated after update"

# Read back
GIGS=$(api "action=get_gigs")
assert_status_ok "$GIGS" "get_gigs returns ok"
GIG_EXISTS=$(echo "$GIGS" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(any(g['gig_id'] == '${GIG_ID}' for g in d.get('gigs',[])))
" 2>/dev/null)
if [[ "$GIG_EXISTS" == "True" ]]; then
  echo -e "  ${GREEN}PASS${NC} gig appears in get_gigs"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC} gig not found in get_gigs"
  ((FAIL++))
  ERRORS+=("get_gigs: test gig not found")
fi

# ============================================================
# TEST GROUP 17: Recommendations
# ============================================================
echo ""
echo -e "${CYAN}=== 17. RECOMMENDATIONS ===${NC}"

RECS=$(api "action=get_recommendations")
assert_status_ok "$RECS" "get_recommendations returns ok"

# ============================================================
# TEST GROUP 18: Monthly Tasks — Save + Load
# ============================================================
echo ""
echo -e "${CYAN}=== 18. MONTHLY TASKS ===${NC}"

LOAD_M=$(api "action=load_monthly")
assert_status_ok "$LOAD_M" "load_monthly returns ok"

if [[ $ON_PRODUCTION -eq 1 ]]; then
  echo -e "  ${YELLOW}SKIP${NC} save_monthly (would overwrite Alex's real monthly tasks)"
else
  # save, then put the original tasks back (in cleanup too, in case we die here)
  MONTHLY_RESTORE=$(echo "$LOAD_M" | python3 -c "
import json, sys, urllib.parse
d = json.load(sys.stdin)
enc = lambda v: v if isinstance(v, str) else json.dumps(v)
q = {'action': 'save_monthly'}
if d.get('tasks') is not None: q['tasks'] = enc(d['tasks'])
if d.get('defaults') is not None: q['defaults'] = enc(d['defaults'])
print(urllib.parse.urlencode(q) if len(q) > 1 else '')" 2>/dev/null)
  SAVE_M=$(api "action=save_monthly&tasks=%5B%7B%22text%22%3A%22test%22%7D%5D&defaults=%5B%5D")
  assert_status_ok "$SAVE_M" "save_monthly returns ok"
  if [[ -n "$MONTHLY_RESTORE" ]]; then
    api "$MONTHLY_RESTORE" > /dev/null && MONTHLY_RESTORE=""
  fi
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo -e "${CYAN}========================================${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  Total: ${TOTAL}  ${GREEN}Pass: ${PASS}${NC}  ${RED}Fail: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo -e "${RED}Failed tests:${NC}"
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} TEST(S) FAILED${NC}"
  exit 1
fi
