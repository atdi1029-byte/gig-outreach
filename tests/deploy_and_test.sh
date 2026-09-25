#!/usr/bin/env bash
# ============================================================
# Gig Outreach — Deploy & Test Script
# Backs up state, deploys new Apps Script, captures endpoint,
# runs full test suite, reports results with rollback guide.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
. "$PROJECT_DIR/env_check.sh" || exit 1

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
# Step 1: Backup the code that is live NOW (the rollback target)
# ---------------------------------------------------------------
# The local apps_script.gs holds the NEW code about to be pasted, so it is not
# a backup. Without clasp the deployed source can't be downloaded; the best
# stand-in is git: the committed version if the local file has uncommitted
# edits, else the version before the last commit that touched it.
echo -e "${CYAN}[1/5] Backing up the currently deployed Apps Script...${NC}"
BACKUP_REF=""
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if ! git -C "$PROJECT_DIR" diff --quiet HEAD -- apps_script.gs 2>/dev/null; then
    BACKUP_REF="HEAD"
  else
    BACKUP_REF=$(git -C "$PROJECT_DIR" log -n 1 --skip=1 --format=%h -- apps_script.gs 2>/dev/null)
  fi
fi
if [[ -n "$BACKUP_REF" ]] && git -C "$PROJECT_DIR" show "${BACKUP_REF}:apps_script.gs" > "$BACKUP_FILE" 2>/dev/null; then
  echo "  Saved git ${BACKUP_REF}:apps_script.gs to: $BACKUP_FILE (the version before this change)"
else
  rm -f "$BACKUP_FILE"
  BACKUP_FILE=""
  echo -e "  ${YELLOW}No git copy of the previous apps_script.gs — roll back with Option C (previous deployment version).${NC}"
fi

CURRENT_URL="${GIG_OUTREACH_URL:-}"
if [[ -z "$CURRENT_URL" && -f "$PROJECT_DIR/.env" ]]; then
  CURRENT_URL=$(grep -E '^(export )?APPS_SCRIPT_URL=' "$PROJECT_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
CURRENT_URL="${CURRENT_URL:-https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec}"
PROD_URLS=" https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec $CURRENT_URL "
REPO_VERSION=$(grep -Eo "^var BACKEND_VERSION *= *'[^']*'" "$PROJECT_DIR/apps_script.gs" | cut -d"'" -f2)
health_field() { echo "$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1], ""))' "$2" 2>/dev/null; }
echo "  Snapshotting current API health..."
HEALTH_BEFORE=$(curl -sL --max-time 15 "${CURRENT_URL}" 2>/dev/null || echo '{"status":"unreachable"}')
VERSION_BEFORE=$(health_field "$HEALTH_BEFORE" version)
echo "  Current API: $(health_field "$HEALTH_BEFORE" status || echo 'parse error')  deployed version: ${VERSION_BEFORE:-none (pre-versioning backend)}"
echo "  Repo apps_script.gs BACKEND_VERSION: ${REPO_VERSION:-missing}"

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
echo "  3. Paste the contents of apps_script.gs (BACKEND_VERSION ${REPO_VERSION:-?}; bump it if you changed the code)"
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

HEALTH_AFTER=$(curl -sL --max-time 15 "${NEW_URL}" 2>/dev/null || echo '{"status":"unreachable"}')
AFTER_STATUS=$(health_field "$HEALTH_AFTER" status)
AFTER_VERSION=$(health_field "$HEALTH_AFTER" version)

if [[ "$AFTER_STATUS" == "ok" && -n "$REPO_VERSION" && "$AFTER_VERSION" != "$REPO_VERSION" ]]; then
  # the endpoint answers, but with other code: usually "New version" wasn't picked
  echo -e "  ${RED}Deployed version is '${AFTER_VERSION:-none}', but apps_script.gs is '${REPO_VERSION}'.${NC}"
  echo -e "  ${RED}The live deployment is not the code you pasted (Deploy > Manage deployments > Edit > Version: New version).${NC}"
  read -p "  Continue anyway? (y/N): " CONTINUE
  if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
    echo "  Aborting. No tests run."
    exit 1
  fi
elif [[ "$AFTER_STATUS" == "ok" ]]; then
  echo -e "  ${GREEN}New deployment is live and responding (version ${AFTER_VERSION:-none}).${NC}"
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
REG_ARGS=()
if [[ "$PROD_URLS" == *" $NEW_URL "* ]]; then
  echo -e "  ${YELLOW}$NEW_URL is the PRODUCTION sheet. The regression suite writes REGTEST_* venues/contacts/gigs"
  echo -e "  there and deletes them again (monthly tasks are not touched).${NC}"
  read -p "  Run the regression suite against production? (y/N): " RUNPROD
  if [[ "$RUNPROD" == "y" || "$RUNPROD" == "Y" ]]; then
    REG_ARGS=(--allow-production)
  else
    REG_ARGS=(SKIP)
  fi
fi
if [[ "${REG_ARGS[0]:-}" == "SKIP" ]]; then
  echo "  Regression suite skipped (production, not confirmed)." | tee "$REPORT_FILE"
else
  GIG_OUTREACH_URL="$NEW_URL" bash "$SCRIPT_DIR/regression_tests.sh" "${REG_ARGS[@]}" 2>&1 | tee "$REPORT_FILE" || REGRESSION_EXIT=$?
fi

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
echo "  Backup:     ${BACKUP_FILE:-none (use Option C)}"
echo "  Version:    before ${VERSION_BEFORE:-none} -> after ${AFTER_VERSION:-none} (repo ${REPO_VERSION:-?})"
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
  echo "  Option C (most reliable): Revert to the previous deployment version"
  echo "    1. Deploy > Manage deployments > Edit"
  echo "    2. Set Version to the previous version number"
  echo "    3. Deploy"
  echo ""
  if [[ -n "$BACKUP_FILE" ]]; then
    echo "  Option A: Paste the previous code (git ${BACKUP_REF}:apps_script.gs)"
    echo "    1. Open https://script.google.com"
    echo "    2. Replace the code with: $BACKUP_FILE"
    echo "    3. Deploy > Manage deployments > Edit > New version > Deploy"
    echo ""
  fi
  echo "  NOTE: the regression suite deletes the REGTEST_* rows it creates; if it died"
  echo "        mid-run, search the sheet for REGTEST_ and delete leftovers by hand."
fi

echo ""
echo "  Full report saved to: $REPORT_FILE"
echo ""

# Exit with failure if any suite failed
if [[ $REGRESSION_EXIT -ne 0 || $TEMPLATE_EXIT -ne 0 ]]; then
  exit 1
fi
