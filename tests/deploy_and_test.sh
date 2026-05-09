#!/usr/bin/env bash
# ============================================================
# Gig Outreach — Deploy & Test Script
# Backs up state, deploys new Apps Script, captures endpoint,
# runs full test suite, reports results with rollback guide.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$PROJECT_DIR/tests/backups"
BACKUP_FILE="$BACKUP_DIR/apps_script_${TIMESTAMP}.gs"
REPORT_FILE="$PROJECT_DIR/tests/deploy_report_${TIMESTAMP}.txt"

mkdir -p "$BACKUP_DIR"

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Gig Outreach — Deploy & Test Pipeline${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# ---------------------------------------------------------------
# Step 1: Backup current Apps Script
# ---------------------------------------------------------------
echo -e "${CYAN}[1/5] Backing up current Apps Script...${NC}"
cp "$PROJECT_DIR/apps_script.gs" "$BACKUP_FILE"
echo "  Saved to: $BACKUP_FILE"

# Also snapshot current endpoint response
CURRENT_URL="${GIG_OUTREACH_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
echo "  Snapshotting current API health..."
HEALTH_BEFORE=$(curl -sL --max-time 15 "${CURRENT_URL}?action=" 2>/dev/null || echo '{"status":"unreachable"}')
echo "  Current API: $(echo "$HEALTH_BEFORE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("status","unknown"))' 2>/dev/null || echo 'parse error')"

# ---------------------------------------------------------------
# Step 2: Deploy new version
# ---------------------------------------------------------------
echo ""
echo -e "${CYAN}[2/5] Deploy new Apps Script version...${NC}"
echo ""
echo -e "${YELLOW}  Apps Script must be deployed manually:${NC}"
echo ""
echo "  1. Open: https://script.google.com"
echo "  2. Find your Gig Outreach project"
echo "  3. Paste the contents of apps_script.gs"
echo "  4. Click Deploy > Manage deployments"
echo "  5. Click the pencil icon on your web app deployment"
echo "  6. Set Version to 'New version'"
echo "  7. Click Deploy"
echo "  8. Copy the new Web App URL"
echo ""
echo -e "${YELLOW}  If using clasp (recommended):${NC}"
echo "    cd $PROJECT_DIR"
echo "    clasp push"
echo "    clasp deploy --description 'v${TIMESTAMP}'"
echo "    # Copy the deployment ID from output"
echo ""

read -p "  Enter new endpoint URL (or press Enter to use current): " NEW_URL
NEW_URL="${NEW_URL:-$CURRENT_URL}"

echo "  Using endpoint: $NEW_URL"

# ---------------------------------------------------------------
# Step 3: Verify new deployment is live
# ---------------------------------------------------------------
echo ""
echo -e "${CYAN}[3/5] Verifying new deployment...${NC}"

HEALTH_AFTER=$(curl -sL --max-time 15 "${NEW_URL}?action=" 2>/dev/null || echo '{"status":"unreachable"}')
AFTER_STATUS=$(echo "$HEALTH_AFTER" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("status","unknown"))' 2>/dev/null || echo 'parse error')

if [[ "$AFTER_STATUS" == "ok" ]]; then
  echo -e "  ${GREEN}New deployment is live and responding.${NC}"
else
  echo -e "  ${RED}WARNING: New deployment returned status='$AFTER_STATUS'${NC}"
  echo -e "  ${RED}The endpoint may not be deployed correctly.${NC}"
  read -p "  Continue anyway? (y/N): " CONTINUE
  if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
    echo "  Aborting. No tests run."
    exit 1
  fi
fi

# ---------------------------------------------------------------
# Step 4: Run full test suite
# ---------------------------------------------------------------
echo ""
echo -e "${CYAN}[4/5] Running regression tests...${NC}"
echo ""

REGRESSION_EXIT=0
GIG_OUTREACH_URL="$NEW_URL" bash "$SCRIPT_DIR/regression_tests.sh" 2>&1 | tee "$REPORT_FILE" || REGRESSION_EXIT=$?

echo "" >> "$REPORT_FILE"
echo "---" >> "$REPORT_FILE"

echo ""
echo -e "${CYAN}[4b/5] Running template smoke tests...${NC}"
echo ""

TEMPLATE_EXIT=0
bash "$SCRIPT_DIR/template_smoke_tests.sh" 2>&1 | tee -a "$REPORT_FILE" || TEMPLATE_EXIT=$?

# ---------------------------------------------------------------
# Step 5: Report
# ---------------------------------------------------------------
echo ""
echo -e "${CYAN}[5/5] Deploy Report${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo "  Timestamp:  $TIMESTAMP"
echo "  Endpoint:   $NEW_URL"
echo "  Backup:     $BACKUP_FILE"
echo "  Report:     $REPORT_FILE"
echo ""

if [[ $REGRESSION_EXIT -eq 0 && $TEMPLATE_EXIT -eq 0 ]]; then
  echo -e "  ${GREEN}ALL TESTS PASSED — deployment is good.${NC}"
  echo ""
  echo "  Next steps:"
  echo "    - Update BASE_URL in index.html if endpoint changed"
  echo "    - Bump service-worker.js version"
  echo "    - git add . && git commit && git push"
else
  echo -e "  ${RED}TESTS FAILED — review report above.${NC}"
  echo ""
  echo -e "  ${YELLOW}ROLLBACK INSTRUCTIONS:${NC}"
  echo ""
  echo "  Option A: Revert Apps Script (keeps data intact)"
  echo "    1. Open https://script.google.com"
  echo "    2. Replace code with: $BACKUP_FILE"
  echo "    3. Deploy > Manage deployments > Edit > New version > Deploy"
  echo ""
  echo "  Option B: Revert via clasp"
  echo "    cp $BACKUP_FILE $PROJECT_DIR/apps_script.gs"
  echo "    cd $PROJECT_DIR && clasp push && clasp deploy"
  echo ""
  echo "  Option C: Revert to previous deployment version"
  echo "    1. Deploy > Manage deployments > Edit"
  echo "    2. Set Version to the previous version number"
  echo "    3. Deploy"
  echo ""
  echo "  NOTE: Test data (REGTEST_ prefixed) is auto-cleaned up."
  echo "        Your real venue/contact data is NOT affected."
fi

echo ""
echo "  Full report saved to: $REPORT_FILE"
echo ""

# Exit with failure if any suite failed
if [[ $REGRESSION_EXIT -ne 0 || $TEMPLATE_EXIT -ne 0 ]]; then
  exit 1
fi
