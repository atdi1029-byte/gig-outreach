#!/bin/bash
# =============================================================
# preflight.sh — is it safe to start (or continue) a run?
#
# Usage: ./preflight.sh [--for pipeline|discover|all] [--no-chrome] [--quick] [--offline]
#   --for      which workflow to check for (default: pipeline)
#   --no-chrome  skip the Chrome checks (tests, or runs that don't drive Chrome)
#   --quick    only the things that can go bad DURING a run (backend, sheet,
#              ZeroBounce budget, Apollo key, Chrome); run it between batches
#   --offline  skip every network check (tests)
#
# Prints one "PREFLIGHT OK|WARN|FAIL: <what>" line per check and a final
# summary line. Exit 0 only if nothing FAILed.
#
# Everything here is free and read-only: syntax checks, a rules self-test,
# GETs of the Apps Script health check + config, the ZeroBounce guard's
# `budget` (a free credit-balance lookup, no validation), Apollo's free
# /auth/health, and one `1+1` in Chrome's active tab.
#
# Env: PREFLIGHT_ZB=require      FAIL (not WARN) when paid ZeroBounce
#                                verification is paused (out of credits, ...)
#      PREFLIGHT_APOLLO=warn     WARN (not FAIL) when the Apollo key is bad
#      ZB_RUN_ID                 run id whose ZeroBounce budget to report
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FOR=pipeline
CHROME=1
QUICK=0
OFFLINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --for) FOR="${2:-}"; shift ;;
        --for=*) FOR="${1#--for=}" ;;
        --no-chrome) CHROME=0 ;;
        --quick) QUICK=1 ;;
        --offline) OFFLINE=1 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "PREFLIGHT FAIL: unknown argument '$1'"; exit 2 ;;
    esac
    shift
done
case "$FOR" in pipeline|discover|all) ;; *) echo "PREFLIGHT FAIL: --for must be pipeline, discover or all"; exit 2 ;; esac

N_OK=0; N_WARN=0; N_FAIL=0; FAILED=""
ok()   { echo "PREFLIGHT OK: $*";   N_OK=$((N_OK + 1)); }
warn() { echo "PREFLIGHT WARN: $*"; N_WARN=$((N_WARN + 1)); }
fail() { local what="${1%% —*}"; echo "PREFLIGHT FAIL: $*"; N_FAIL=$((N_FAIL + 1)); FAILED="${FAILED:+$FAILED; }${what:0:50}"; }
needs() { [ "$FOR" = all ] || case " $* " in *" $FOR "*) return 0 ;; *) return 1 ;; esac; }

# with_timeout SECS cmd... (macOS has no `timeout`; perl's alarm survives exec)
with_timeout() {
    local secs="$1"; shift
    if [ -x /usr/bin/perl ]; then /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"; else "$@"; fi
}

cd "$SCRIPT_DIR" || { echo "PREFLIGHT FAIL: cannot cd to $SCRIPT_DIR"; exit 1; }

# ---------------------------------------------------------------- python
if . "$SCRIPT_DIR/env_check.sh" 2>/tmp/preflight_env_$$; then
    ok "python3 works ($(python3 -c 'import sys; print(sys.executable, sys.version.split()[0])' 2>/dev/null))"
else
    fail "python3 — $(tr '\n' ' ' < /tmp/preflight_env_$$)"
    rm -f /tmp/preflight_env_$$
    echo "PREFLIGHT FAIL: 1 check(s) failed (python3); nothing else can run"
    exit 1
fi
rm -f /tmp/preflight_env_$$

# ---------------------------------------------------------------- config
ENV_FILE="$SCRIPT_DIR/.env"
envval() { [ -f "$ENV_FILE" ] && grep -E "^(export )?$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
[ -z "${APPS_SCRIPT_URL:-}" ] && APPS_SCRIPT_URL="$(envval APPS_SCRIPT_URL)"
if [ -z "${APPS_SCRIPT_URL:-}" ]; then
    APPS_SCRIPT_URL="https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
    [ "$QUICK" = 0 ] && warn "APPS_SCRIPT_URL not in .env — using the hardcoded URL"
fi
[ -z "${APOLLO_API_KEY:-}" ] && APOLLO_API_KEY="$(envval APOLLO_API_KEY)"
APOLLO_API_BASE="${APOLLO_API_BASE:-https://api.apollo.io/api/v1}"
if [ "$QUICK" = 0 ] && needs pipeline; then
    [ -n "$(envval ZEROBOUNCE_KEY)${ZEROBOUNCE_KEY:-}" ] && ok ".env has ZEROBOUNCE_KEY" || warn ".env has no ZEROBOUNCE_KEY — every personal email will be deferred"
    [ -n "$APOLLO_API_KEY" ] && ok ".env has APOLLO_API_KEY" || fail "APOLLO_API_KEY missing from .env — the Apollo step cannot run"
fi

# ---------------------------------------------------------------- static checks (full mode)
if [ "$QUICK" = 0 ]; then
    bad=""; n=0
    for f in "$SCRIPT_DIR"/*.sh; do
        n=$((n + 1))
        # one file per call: `bash -n a.sh b.sh` only checks a.sh
        err=$(bash -n "$f" 2>&1) || bad="${bad:+$bad; }$(basename "$f"): $(echo "$err" | head -1)"
    done
    [ -z "$bad" ] && ok "bash -n: $n scripts parse" || fail "bash -n — $bad"

    out=$(python3 "$SCRIPT_DIR/tests/check_heredocs.py" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then ok "embedded python: $(echo "$out" | tail -1)"
    else fail "embedded python — $(echo "$out" | grep '^FAIL' | head -3 | tr '\n' ' ')($(echo "$out" | tail -1))"; fi

    out=$(python3 - "$SCRIPT_DIR" 2>&1 <<'PY'
import glob, os, sys
bad = []
for p in sorted(glob.glob(os.path.join(sys.argv[1], '*.py'))):
    try:
        compile(open(p, encoding='utf-8', errors='replace').read(), p, 'exec')
    except SyntaxError as e:
        bad.append(f"{os.path.basename(p)}:{e.lineno}: {e.msg}")
print('; '.join(bad) if bad else f"{len(glob.glob(os.path.join(sys.argv[1], '*.py')))} python files compile")
sys.exit(1 if bad else 0)
PY
); [ $? -eq 0 ] && ok "$out" || fail "python files — $out"

    out=$(python3 - "$SCRIPT_DIR" 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import outreach_rules as R
checks = [
    (R.TARGET_STATES == ('DC', 'MD', 'VA'), 'target states are DC/MD/VA'),
    (R.check_email('jane@venue.com', 'https://www.venue.com', 'Venue')['action'] == 'verify', 'own-domain personal email -> verify'),
    (R.check_email('events@venue.com', 'venue.com', 'Venue')['action'] == 'role', 'role mailbox -> role'),
    (R.check_email('bob@vendor.com', 'venue.com', 'Venue')['action'] == 'reject', 'off-domain -> reject'),
    (R.check_email('noreply@venue.com', 'venue.com', 'Venue')['action'] == 'reject', 'noreply -> reject'),
    (R.check_email('someone@gmail.com', 'venue.com', 'Venue')['action'] == 'reject', 'unlinked free-mail -> reject'),
    (R.check_email('bistrovenue@gmail.com', 'venue.com', 'Bistro Venue', found_on_venue_site=True)['action'] == 'verify', 'free-mail with venue token on own site -> verify'),
    (R.clean_person_name('Liz McQuay') == 'Liz McQuay', 'clean-name keeps a real name'),
    (R.clean_person_name('Jane D***e') == '', 'clean-name drops masked Apollo names'),
    (R.name_from_email('info@x.com') == '', 'no name invented from info@'),
    (not R.org_name_matches('La Lou Bistro', 'Petit Louis Bistro'), 'org-matches rejects look-alike names'),
    (R.org_name_matches('Gvino', 'Gvino Wine Bar'), 'org-matches accepts a short form'),
    (R.registrable_domain('https://events.sub.example.co.uk/x') == 'example.co.uk', 'registrable domain'),
    (R.is_shared_domain('https://www.sonesta.com/va/falls-church'), 'shared brand domain'),
]
bad = [name for good, name in checks if not good]
print('outreach_rules self-test: ' + (f'{len(checks)} checks pass' if not bad else 'FAILED: ' + '; '.join(bad)))
sys.exit(1 if bad else 0)
PY
); [ $? -eq 0 ] && ok "$out" || fail "$out"

    if [ -f "$SCRIPT_DIR/venue_classifier.py" ]; then
        out=$(python3 "$SCRIPT_DIR/venue_classifier.py" --test 2>&1); rc=$?
        last=$(echo "$out" | tail -1)
        [ $rc -eq 0 ] && ok "venue_classifier self-test: $last" || fail "venue_classifier self-test — $last"
    fi

    if needs pipeline discover && ls "$SCRIPT_DIR"/js/*.js >/dev/null 2>&1; then
        if command -v node >/dev/null 2>&1; then
            bad=""
            for f in "$SCRIPT_DIR"/js/*.js; do node --check "$f" >/dev/null 2>&1 || bad="${bad:+$bad, }$(basename "$f")"; done
            [ -z "$bad" ] && ok "js/*.js extractors parse (node --check)" || fail "js extractors with syntax errors: $bad"
        else
            warn "node not installed — js/*.js extractors not syntax-checked"
        fi
    fi
fi

# ---------------------------------------------------------------- Apps Script
if [ "$OFFLINE" = 0 ]; then
    health=""
    for try in 1 2 3; do
        health=$(curl -sL --max-time 20 "$APPS_SCRIPT_URL" 2>/dev/null)
        printf '%s' "$health" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("status")=="ok" else 1)' 2>/dev/null && break
        health=""; sleep 2
    done
    if [ -z "$health" ]; then
        fail "Apps Script backend unreachable or not ok ($APPS_SCRIPT_URL)"
    else
        repo_ver=$(grep -Eo "^var BACKEND_VERSION *= *'[^']*'" "$SCRIPT_DIR/apps_script.gs" 2>/dev/null | cut -d"'" -f2)
        live_ver=$(printf '%s' "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)
        if [ -z "$live_ver" ]; then
            warn "Apps Script is up but reports no version (the pre-${repo_ver:-C5} backend): redeploy apps_script.gs to get created/duplicate flags and server-side checks"
        elif [ -n "$repo_ver" ] && [[ "$live_ver" < "$repo_ver" ]]; then
            warn "Apps Script backend $live_ver is older than the repo ($repo_ver) — redeploy apps_script.gs"
        else
            ok "Apps Script backend up (version $live_ver)"
        fi
        cfg=$(curl -sL --max-time 30 "${APPS_SCRIPT_URL}?action=config" 2>/dev/null)
        if printf '%s' "$cfg" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("status")=="ok" else 1)' 2>/dev/null; then
            ok "sheet readable (action=config)"
        else
            fail "sheet not readable (action=config returned: $(printf '%s' "$cfg" | head -c 120))"
        fi
    fi
fi

# ---------------------------------------------------------------- ZeroBounce (free balance check through the guard)
if needs pipeline && [ "$OFFLINE" = 0 ]; then
    zb=$(python3 "$SCRIPT_DIR/zerobounce_guard.py" budget --run-id "${ZB_RUN_ID:-preflight-$$}" 2>/dev/null)
    # JSON goes in through the environment: a heredoc script can't also read a pipe on stdin
    line=$(ZB_JSON="$zb" python3 - "${ZB_DB_PATH:-$HOME/.outreach/zerobounce_guard.sqlite3}" 2>/dev/null <<'PY'
import json, os, sqlite3, sys
d = json.loads(os.environ['ZB_JSON'])
src = d.get('settings') or {}
def fmt(key, val):
    s = src.get(key, {}).get('source')
    return f"{val}{'' if not s else ' (' + s + ')'}"
bal = d.get('credits_remaining')
parts = [f"enabled={fmt('ZB_ENABLED', d.get('enabled', d.get('reason') != 'disabled'))}",
         f"balance={bal if bal is not None else 'unknown'}", f"reserve={fmt('ZB_MIN_BALANCE', d.get('reserve'))}",
         f"run {d.get('run_used', 0)}/{fmt('ZB_MAX_PER_RUN', d.get('run_limit'))}",
         f"today {d.get('day_used', 0)}/{fmt('ZB_MAX_PER_DAY', d.get('day_limit'))}"]
try:   # headroom in typical runs, from the guard's own usage table (read-only)
    con = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
    per = [r[0] for r in con.execute("SELECT COUNT(*) FROM usage WHERE run_id LIKE 'pipeline-%' GROUP BY run_id "
                                     "ORDER BY MAX(used_at) DESC LIMIT 10")]
    if per and isinstance(bal, int):
        avg = max(1, sum(per) // len(per))
        parts.append(f"~{max(0, bal - int(d.get('reserve') or 0)) // avg} runs of headroom at {avg}/run")
except Exception:
    pass
print(('ALLOWED' if d.get('allowed') else 'PAUSED:' + str(d.get('reason'))) + '\t' + ', '.join(parts))
PY
)
    if [ -z "$line" ]; then
        fail "ZeroBounce guard did not answer (python3 zerobounce_guard.py budget)"
    elif [ "${line%%$'\t'*}" = "ALLOWED" ]; then
        ok "ZeroBounce: ${line#*$'\t'}"
    elif [ "${PREFLIGHT_ZB:-warn}" = require ]; then
        fail "ZeroBounce paid verification ${line%%$'\t'*} — ${line#*$'\t'}"
    else
        warn "ZeroBounce paid verification ${line%%$'\t'*} — personal emails will be saved as UNVERIFIED (run ./reverify.sh --unverified after topping up) — ${line#*$'\t'}"
    fi
fi

# ---------------------------------------------------------------- Apollo (free auth health)
if needs pipeline && [ "$OFFLINE" = 0 ] && [ -n "$APOLLO_API_KEY" ]; then
    ah=$(curl -s --max-time 20 -H "X-Api-Key: $APOLLO_API_KEY" -H 'Cache-Control: no-cache' "${APOLLO_API_BASE%/}/auth/health" 2>/dev/null)
    state=$(printf '%s' "$ah" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("is_logged_in") else "bad:" + json.dumps(d)[:120])' 2>/dev/null)
    if [ "$state" = ok ]; then
        ok "Apollo API key accepted (auth/health)"
    elif [ "${PREFLIGHT_APOLLO:-require}" = warn ]; then
        warn "Apollo key not accepted — Apollo step will fail for every venue (${state:-no answer: $(printf '%s' "$ah" | head -c 80)})"
    else
        fail "Apollo key not accepted by auth/health (${state:-no answer: $(printf '%s' "$ah" | head -c 80)}); renew it or set PREFLIGHT_APOLLO=warn"
    fi
fi

# ---------------------------------------------------------------- Chrome
if [ "$CHROME" = 1 ] && needs pipeline discover; then
    if ! pgrep -x "Google Chrome" >/dev/null 2>&1; then
        fail "Google Chrome is not running (open it, logged into LinkedIn/Google)"
    else
        js=$(with_timeout 15 osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "1+1"' 2>&1)
        case "$js" in
            2|2.0) ok "Chrome runs JavaScript from Apple Events" ;;
            *"turned off"*|*"Allow JavaScript"*) fail "Chrome: View > Developer > Allow JavaScript from Apple Events is OFF" ;;
            *"front window"*|*"-1719"*|*"-1728"*) fail "Chrome has no open window" ;;
            "") fail "Chrome did not answer within 15s (hung or a modal dialog is open)" ;;
            *) fail "Chrome JavaScript check failed: $(echo "$js" | head -1 | cut -c1-120)" ;;
        esac
    fi
fi

# ---------------------------------------------------------------- summary
if [ "$N_FAIL" -gt 0 ]; then
    echo "PREFLIGHT FAIL: $N_FAIL check(s) failed ($FAILED); $N_OK ok, $N_WARN warn"
    exit 1
fi
mode="$FOR"; [ "$QUICK" = 1 ] && mode="$mode, quick"; [ "$CHROME" = 0 ] && mode="$mode, no chrome"; [ "$OFFLINE" = 1 ] && mode="$mode, offline"
echo "PREFLIGHT OK: all checks passed ($mode; $N_OK ok, $N_WARN warn)"
exit 0
