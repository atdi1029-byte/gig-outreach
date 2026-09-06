#!/usr/bin/env bash
# diag_chrome.sh — pre-flight check for Chrome scraping
#
# Tests:
#   1. Chrome is running and JS from Apple Events works
#   2. LinkedIn session is active (not logged out)
#
# Exit codes: 0 = all pass, 1 = something failed

set -euo pipefail

PASS=0
FAIL=0

test_result() {
  local name="$1" result="$2" detail="${3:-}"
  if [[ "$result" == "pass" ]]; then
    echo "  PASS  Test $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  Test $name${detail:+  — $detail}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Chrome Diagnostics ==="
echo ""

# Test 1: Chrome running + JS from Apple Events
TITLE=$(osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "document.title"' 2>/dev/null || echo "")
if [[ -n "$TITLE" && "$TITLE" != "missing value" ]]; then
  test_result "1 (Chrome JS)" "pass"
else
  # Check if Chrome is running at all
  if pgrep -q "Google Chrome"; then
    test_result "1 (Chrome JS)" "fail" "Chrome is running but JS from Apple Events failed. Enable: View > Developer > Allow JavaScript from Apple Events"
  else
    test_result "1 (Chrome JS)" "fail" "Chrome is not running"
  fi
fi

# Test 2: LinkedIn session
LI_CHECK=$(osascript <<'EOF' 2>/dev/null || echo "error"
tell application "Google Chrome"
  set oldURL to URL of active tab of front window
  set URL of active tab of front window to "https://www.linkedin.com/feed/"
  delay 3
  set pageTitle to execute active tab of front window javascript "document.title"
  set URL of active tab of front window to oldURL
  return pageTitle
end tell
EOF
)
if [[ "$LI_CHECK" == *"Feed"* || "$LI_CHECK" == *"LinkedIn"* ]] && [[ "$LI_CHECK" != *"Log In"* && "$LI_CHECK" != *"Sign In"* ]]; then
  test_result "2 (LinkedIn session)" "pass"
else
  test_result "2 (LinkedIn session)" "fail" "Not logged into LinkedIn (got: $LI_CHECK)"
fi

echo ""
echo "Results: $PASS pass, $FAIL fail"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
