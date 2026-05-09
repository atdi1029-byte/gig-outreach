#!/usr/bin/env bash
# ============================================================
# Gig Outreach — Regression Test Suite
# Hits the Apps Script endpoint via curl, verifies responses,
# reads back data to confirm persistence.
# ============================================================
set -uo pipefail

# --- Config ---
BASE_URL="${GIG_OUTREACH_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
TEST_PREFIX="REGTEST_$(date +%s)"
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

# Track test venue/contact/gig IDs for cleanup
CLEANUP_VENUE_IDS=()
CLEANUP_CONTACT_IDS=()
CLEANUP_GIG_IDS=()

cleanup() {
  echo ""
  echo -e "${CYAN}=== CLEANUP ===${NC}"
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

# ============================================================
# TEST GROUP 2: Add Venue
# Bug caught: venues disappearing (912b37d), duplicate IDs
# ============================================================
echo ""
echo -e "${CYAN}=== 2. ADD VENUE ===${NC}"

VENUE_NAME="${TEST_PREFIX}_TestWinery"
ADD_VENUE=$(api "action=add_venue&name=${VENUE_NAME}&category=winery&website=https://test.example.com&city=Annapolis&state=MD&source=regression_test&upscale_score=4&zone_priority=green")
assert_status_ok "$ADD_VENUE" "add_venue returns ok"

TEST_VENUE_ID=$(echo "$ADD_VENUE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('venue_id',''))" 2>/dev/null)
CLEANUP_VENUE_IDS+=("$TEST_VENUE_ID")
echo "  Created venue: $TEST_VENUE_ID"

# Read back via venue_detail
DETAIL=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_status_ok "$DETAIL" "venue_detail returns ok"
assert_json_field "$DETAIL" "venue.name" "$VENUE_NAME" "venue name persisted correctly"
assert_json_field "$DETAIL" "venue.category" "winery" "venue category persisted"
assert_json_field "$DETAIL" "venue.city" "Annapolis" "venue city persisted"
assert_json_field "$DETAIL" "venue.state" "MD" "venue state persisted"
assert_json_field "$DETAIL" "venue.status" "untouched" "new venue starts as untouched"
assert_json_field "$DETAIL" "venue.zone_priority" "green" "venue zone_priority persisted"

# Duplicate detection
DUP=$(api "action=add_venue&name=${VENUE_NAME}&category=winery&state=MD")
assert_json_contains "$DUP" "message" "Duplicate" "duplicate venue detected by name+state"

# ============================================================
# TEST GROUP 3: Add Contact
# Bug caught: duplicate contact_id (d3ed927), generic email
# filtering (fe06536)
# ============================================================
echo ""
echo -e "${CYAN}=== 3. ADD CONTACT ===${NC}"

ADD_CONTACT=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Jane+Doe&title=Events+Manager&email=${TEST_PREFIX}@example.com&source=regression_test&verified=valid")
assert_status_ok "$ADD_CONTACT" "add_contact returns ok"

TEST_CONTACT_ID=$(echo "$ADD_CONTACT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('contact_id',''))" 2>/dev/null)
CLEANUP_CONTACT_IDS+=("$TEST_CONTACT_ID")
echo "  Created contact: $TEST_CONTACT_ID"

# Read back via venue_detail
DETAIL2=$(api "action=venue_detail&venue_id=${TEST_VENUE_ID}")
assert_json_field "$DETAIL2" "contacts.0.name" "Jane Doe" "contact name persisted"
assert_json_field "$DETAIL2" "contacts.0.title" "Events Manager" "contact title persisted"
assert_json_field "$DETAIL2" "contacts.0.email" "${TEST_PREFIX}@example.com" "contact email persisted"
assert_json_field "$DETAIL2" "contacts.0.verified" "valid" "contact verified status persisted"
assert_json_field "$DETAIL2" "contacts.0.source" "regression_test" "contact source persisted"

# Duplicate contact detection (same email + venue)
DUP_CONTACT=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&email=${TEST_PREFIX}@example.com&name=Jane+Doe")
assert_json_contains "$DUP_CONTACT" "message" "Duplicate" "duplicate contact email detected"

# Add second contact to test multi-contact venue
ADD_C2=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Bob+Smith&title=Owner&email=${TEST_PREFIX}_2@example.com&source=regression_test&verified=valid")
TEST_CONTACT_ID2=$(echo "$ADD_C2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('contact_id',''))" 2>/dev/null)

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
UPD_EMAIL=$(api "action=update_contact_email&venue_id=${TEST_VENUE_ID}&name=Jane+Doe&email=jane.updated@example.com&verified=valid&source=apollo")
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
UPD_NEW=$(api "action=update_contact_email&venue_id=${TEST_VENUE_ID}&name=New+Person&email=newperson@example.com&verified=valid&source=apollo&title=Chef")
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
ADD_DEL=$(api "action=add_contact&venue_id=${TEST_VENUE_ID}&name=Delete+Me&email=deleteme_${TEST_PREFIX}@example.com&source=test&verified=pending")
DEL_CID=$(echo "$ADD_DEL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('contact_id',''))" 2>/dev/null)

DEL_RESULT=$(api "action=delete_contact&contact_id=${DEL_CID}")
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
ADD_V2=$(api "action=add_venue&name=${TEST_PREFIX}_DeleteMe&category=hotel&state=VA&city=Arlington")
DEL_VID=$(echo "$ADD_V2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('venue_id',''))" 2>/dev/null)
api "action=add_contact&venue_id=${DEL_VID}&name=Cascade+Test&email=cascade_${TEST_PREFIX}@example.com&verified=pending" > /dev/null

DEL_V=$(api "action=delete_venue&venue_id=${DEL_VID}")
assert_status_ok "$DEL_V" "delete_venue returns ok"

# Verify venue gone
DETAIL13=$(api "action=venue_detail&venue_id=${DEL_VID}")
assert_json_field "$DETAIL13" "status" "error" "deleted venue returns error on detail lookup"

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

SAVE_M=$(api "action=save_monthly&tasks=%5B%7B%22text%22%3A%22test%22%7D%5D&defaults=%5B%5D")
assert_status_ok "$SAVE_M" "save_monthly returns ok"

LOAD_M=$(api "action=load_monthly")
assert_status_ok "$LOAD_M" "load_monthly returns ok"

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
