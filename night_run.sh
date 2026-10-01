#!/bin/bash
# =============================================================
# night_run.sh — the unattended night run (Alex, Sep 29 2026: "run by yourself at night,
# runs of 50, push everything after each run, go deeper on 0-contact venues and fix the
# code, and if Apollo or ZeroBounce run out, stop and put an alert in the app").
#
# launchd starts it at 1:00 through Terminal (night_run.command), so Chrome automation
# runs with Terminal's permission. Everything it does is logged to
# reports/runs/night-YYYYMMDD.log and summed up in night_status.json (the app shows it).
#
#   ./night_run.sh            the night (only between 00:30 and 03:30, see --force)
#   ./night_run.sh --check    credit + setup checks only: no run, no status, no push
#   ./night_run.sh --force    run now, whatever the time (same cutoff rules)
#   ./night_run.sh --dive RUN_ID
#                             only the deep dive of one run's zero-contact venues (research,
#                             save, push): no pipeline, no Chrome. A test of the Claude step.
#
# The night:
#   1. checks: kill switch (.night_off), ZeroBounce, Apollo credits. Out = alert + stop.
#   2. re-checks emails saved as unverified, promotes verified sweep finds (verify_pool.py)
#      and gives LinkedIn another try on venues it skipped before (pipeline.sh --linkedin-retry).
#      Missing websites: a Claude session looks them up with WebSearch in the background
#      (NIGHT_WEBSITES.md), never Chrome; its URLs are checked and saved between runs.
#   3. up to NIGHT_MAX_RUNS runs of RUN_SIZE (pipeline.sh --run, or --resume of a run a
#      stop or the cutoff left unfinished). No batch starts that can't end by NIGHT_CUTOFF.
#      After each run: commit + push, then a Claude session researches the run's
#      zero-contact venues (NIGHT_DEEPDIVE.md, phase research) while the next run goes;
#      night_save.py writes what it found; commit + push.
#   4. after the last run: one Claude session fixes the scraper for what the pipeline
#      missed (phase fix, recall benchmark as the test), then commit + push.
# A stop (credits, preflight) ends the night; the app shows why. A Chrome stop is first
# tried again, CHROME_RETRIES times CHROME_RETRY_WAIT_S apart. Google's CAPTCHA doesn't stop
# a run: the scripts stop searching Google until it lets up and go on (google_guard.sh). The night needs Chrome to
# itself: another copy of Chrome is waited for, then closed if a program started it
# (CHROME_ALONE_KILL, chrome_guard.sh).
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

MODE="night"
DIVE_ONLY=""
case "${1:-}" in
    --check) MODE="check" ;;
    --force) MODE="force" ;;
    --dive) MODE="dive"; DIVE_ONLY="${2:-}" ;;
    "") ;;
    *) echo "usage: $0 [--check|--force|--dive RUN_ID]"; exit 2 ;;
esac

# Keep the Mac awake for the whole night (idle, disk and, on power, system sleep)
if [ "$MODE" != "check" ] && [ -z "${NIGHT_CAFFEINATED:-}" ]; then
    export NIGHT_CAFFEINATED=1
    exec caffeinate -ims "$SCRIPT_DIR/$(basename "$0")" "$@"
fi

. "$SCRIPT_DIR/env_check.sh" || exit 1
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

RUN_SIZE="${RUN_SIZE:-50}"
NIGHT_MAX_RUNS="${NIGHT_MAX_RUNS:-2}"
NIGHT_START_EARLIEST="${NIGHT_START_EARLIEST:-0030}"   # HHMM: a launch outside this
NIGHT_START_LATEST="${NIGHT_START_LATEST:-0330}"       # window is a missed night
NIGHT_CUTOFF="${NIGHT_CUTOFF:-0800}"                   # HHMM: Chrome is Alex's again
MIN_RUN_WINDOW_MIN="${MIN_RUN_WINDOW_MIN:-60}"         # don't start a run with less left
DEEPDIVE_MAX_MIN="${DEEPDIVE_MAX_MIN:-100}"
FIX_MAX_MIN="${FIX_MAX_MIN:-120}"
FIX_LATEST="${FIX_LATEST:-1100}"                       # HHMM: no fix session starts later
APOLLO_MIN_CREDITS="${APOLLO_MIN_CREDITS:-100}"
MAX_RESUMES="${MAX_RESUMES:-2}"                        # stops (not cutoffs) before a run is dropped
CHROME_RETRIES="${CHROME_RETRIES:-3}"                  # a Chrome stop is tried again this many times
CHROME_RETRY_WAIT_S="${CHROME_RETRY_WAIT_S:-600}"      # ...this long apart, before the night gives up
GOOGLE_RETRY_WAIT_S="${GOOGLE_RETRY_WAIT_S:-1800}"     # ...or this long when Google's CAPTCHA stopped it
BACKFILL_LIMIT="${BACKFILL_LIMIT:-30}"                 # venues whose website Claude looks up per night
WEBSITES_MAX_MIN="${WEBSITES_MAX_MIN:-45}"             # ...in a session killed after this long
LI_RETRY_MAX_MIN="${LI_RETRY_MAX_MIN:-30}"             # LinkedIn retry of skipped venues, before the runs
# The night needs Chrome to itself (Alex, Sep 30 2026: "we need to run alone"): the scripts
# wait for another copy of Chrome to close, and at night then close a copy a program
# started, such as a headless test browser (chrome_guard.sh)
export CHROME_ALONE_KILL="${CHROME_ALONE_KILL:-1}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo /usr/local/bin/claude)}"
RUNS_DIR="$SCRIPT_DIR/reports/runs"
STATE="$RUNS_DIR/night-state.json"
NIGHT_LOG="$RUNS_DIR/night-$(date +%Y%m%d).log"
LOCK_DIR="/tmp/night_run.lock.d"
GIT_LOCK="/tmp/night_git.lock.d"
PIPE_LOCK="/tmp/pipeline.lock.d"
DIVE_PID=""
DIVE_RID=""
mkdir -p "$RUNS_DIR"

if [ "$MODE" != "check" ]; then
    exec > >(tee -a "$NIGHT_LOG") 2>&1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }
status() { /usr/bin/python3 "$SCRIPT_DIR/night_status.py" "$@" >/dev/null || log "WARN: night_status.py $1 failed"; }
hhmm() { date +%H%M; }

# state.json helpers: resume target, attempts, runs whose misses still need a fix session
state_get() {
    /usr/bin/python3 - "$STATE" "$1" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    d = {}
v = d.get(sys.argv[2], "")
print(" ".join(v) if isinstance(v, list) else v)
PYEOF
}
state_set() {   # state_set KEY VALUE   (VALUE "" deletes; KEY fix_pending takes a space list)
    /usr/bin/python3 - "$STATE" "$1" "$2" <<'PYEOF'
import json, os, sys
p, k, v = sys.argv[1:4]
try:
    d = json.load(open(p))
except (OSError, ValueError):
    d = {}
if k == "fix_pending":
    v = [x for x in v.split() if x]
if v in ("", []):
    d.pop(k, None)
else:
    d[k] = v
tmp = p + ".tmp"
json.dump(d, open(tmp, "w"), indent=1)
os.replace(tmp, p)
PYEOF
}

deadline_epoch() {   # today's NIGHT_CUTOFF (a night always starts after midnight)
    date -j -f "%Y%m%d%H%M%S" "$(date +%Y%m%d)${NIGHT_CUTOFF}00" +%s
}
minutes_left() { echo $(( ( $(deadline_epoch) - $(date +%s) ) / 60 )); }

# guarded SECONDS CMD...: run CMD, kill its whole process tree after SECONDS. 124 = killed.
proc_tree() { local p="$1" c; echo "$p"; for c in $(pgrep -P "$p" 2>/dev/null); do proc_tree "$c"; done; }
guarded() {
    local secs="$1" waited=0 pid
    shift
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            log "WATCHDOG: $1 still running after $((secs / 60)) min — stopping it"
            kill -TERM $(proc_tree "$pid") 2>/dev/null; sleep 5; kill -KILL $(proc_tree "$pid") 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 5
        waited=$((waited + 5))
    done
    wait "$pid"
}

# ---------------------------------------------------------------- git
git_sync() {   # git_sync "message" FILE...  — commit what exists of FILE..., then push
    local msg="$1" f files=() i
    shift
    for f in "$@"; do [ -e "$f" ] && files+=("$f"); done
    for i in $(seq 1 60); do mkdir "$GIT_LOCK" 2>/dev/null && break; sleep 5; done
    if [ ${#files[@]} -gt 0 ]; then
        git add -- "${files[@]}" 2>/dev/null
        if ! git diff --cached --quiet; then
            git commit -q -m "$msg" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && log "Committed: $msg"
        fi
    fi
    for i in 1 2 3; do
        if GIT_TERMINAL_PROMPT=0 git push -q origin HEAD:main 2>&1; then log "Pushed"; break; fi
        log "Push failed (try $i) — pulling and retrying"
        GIT_TERMINAL_PROMPT=0 git pull -q --rebase --autostash origin main 2>&1 || git rebase --abort 2>/dev/null
        sleep 15
    done
    rmdir "$GIT_LOCK" 2>/dev/null
}
status_push() { git_sync "Night status: $1" night_status.json; }

# ---------------------------------------------------------------- checks
ZB_DETAIL=""
zb_check() {   # 0 = ZeroBounce usable. Sets ZB_DETAIL to a plain explanation otherwise.
    local out allowed reason credits raw
    out=$(/usr/bin/python3 "$SCRIPT_DIR/zerobounce_guard.py" budget --run-id "night-check-$$" 2>/dev/null)
    allowed=$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("allowed"), d.get("reason"), d.get("credits_remaining"))' 2>/dev/null)
    read -r allowed reason credits <<< "$allowed"
    [ "$allowed" = "True" ] && { log "ZeroBounce OK (balance $credits)"; return 0; }
    case "$reason" in
        reserve_reached) ZB_DETAIL="ZeroBounce is out of credits (balance ${credits:-0}, the floor is ${ZB_MIN_BALANCE:-100}). Top up and the next night picks up where this one stopped." ;;
        day_budget_reached|run_budget_reached) ZB_DETAIL="ZeroBounce hit the daily safety cap (${ZB_MAX_PER_DAY:-400} checks). The next night continues." ;;
        disabled) ZB_DETAIL="ZeroBounce is switched off (ZB_ENABLED=0 in .env)." ;;
        no_api_key) ZB_DETAIL="There is no ZeroBounce key in .env." ;;
        *)
            raw=$(curl -s --max-time 30 "https://api.zerobounce.net/v2/getcredits?api_key=${ZEROBOUNCE_KEY}" 2>/dev/null)
            case "$raw" in
                *"not whitelisted"*)
                    ZB_DETAIL="ZeroBounce is refusing this internet address ($(curl -s --max-time 10 https://api.ipify.org 2>/dev/null)). The Mac isn't on your home network, or your home IP changed: whitelist it in ZeroBounce." ;;
                *'"Credits"'*)
                    ZB_DETAIL="ZeroBounce answered but the guard refused (${reason:-unknown}; ${raw:0:80})." ;;
                *)
                    ZB_DETAIL="ZeroBounce couldn't be reached (${reason:-unknown}${raw:+; ${raw:0:80}}). No internet, or ZeroBounce is down." ;;
            esac ;;
    esac
    log "ZeroBounce NOT usable: $ZB_DETAIL"
    return 1
}

APOLLO_LEFT=""
apollo_check() {   # 0 = fine or unknown; 1 = below APOLLO_MIN_CREDITS
    APOLLO_LEFT=$(curl -s --max-time 30 -H "X-Api-Key: ${APOLLO_API_KEY}" -H "Cache-Control: no-cache" \
        "https://api.apollo.io/api/v1/users/api_profile?include_credit_usage=true" 2>/dev/null |
        /usr/bin/python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("num_credits_remaining")))
except Exception: print("")' 2>/dev/null)
    if [ -z "$APOLLO_LEFT" ]; then
        log "Apollo balance unknown (API didn't say) — going on; the pipeline stops if Apollo keeps failing"
        return 0
    fi
    log "Apollo credits left: $APOLLO_LEFT (stop below $APOLLO_MIN_CREDITS)"
    [ "$APOLLO_LEFT" -ge "$APOLLO_MIN_CREDITS" ]
}

# ---------------------------------------------------------------- stop reasons
# classify_stop "reason text" -> sets STOP_KIND (deadline|zerobounce|apollo|chrome|error)
STOP_KIND=""
classify_stop() {
    case "$1" in
        deadline:*) STOP_KIND="deadline" ;;
        # chrome_guard.sh's words first: the copy it names may have been started by anything
        *"another copy of Google Chrome"*|*"Google Chrome is not running"*) STOP_KIND="chrome" ;;
        *ZeroBounce*) STOP_KIND="zerobounce" ;;
        *Apollo*) STOP_KIND="apollo" ;;
        *Chrome*|*curl*|*watchdog*|*social/Google*) STOP_KIND="chrome" ;;
        *) STOP_KIND="error" ;;
    esac
}
google_block() { case "$1" in *social/Google*|*CAPTCHA*) return 0 ;; esac; return 1; }

LAST_STARTED=1     # 0 when the last run couldn't start (preflight etc.): nothing registered
LAST_RESUMABLE=1   # 0 when the last run won't resume (never started, or dropped)
CHROME_TRIED=0     # Chrome stops tried again tonight
alert_for_stop() {   # alert_for_stop RUN_ID "reason"
    local rid="$1" reason="$2" next tried="" advice
    next="Run $rid resumes next night."
    if [ "$LAST_RESUMABLE" != 1 ]; then
        next="The next night starts a fresh run."
        [ "$LAST_STARTED" = 0 ] && next="No venues had started, so none were used up. $next"
    fi
    [ "$CHROME_TRIED" -gt 0 ] && tried=" Tried again $CHROME_TRIED time(s), $((CHROME_RETRY_WAIT_S / 60)) min apart."
    classify_stop "$reason"
    case "$STOP_KIND" in
        zerobounce)
            zb_check >/dev/null
            status alert zerobounce stop "Night runs paused: ZeroBounce" "${ZB_DETAIL:-$reason}. $next" ;;
        apollo)
            apollo_check >/dev/null
            if [ -n "$APOLLO_LEFT" ] && [ "$APOLLO_LEFT" -lt "$APOLLO_MIN_CREDITS" ]; then
                status alert apollo stop "Night runs paused: Apollo credits" "Apollo has $APOLLO_LEFT credits left (the floor is $APOLLO_MIN_CREDITS). Top up and the next night picks up again. $next"
            else
                status alert apollo warn "Apollo kept failing" "$reason. Credits left: ${APOLLO_LEFT:-unknown}. The next night tries again."
            fi ;;
        chrome)
            if google_block "$reason"; then
                status alert chrome warn "Google kept blocking searches" "$reason.$tried $next Nothing to do: the block wears off by itself."
            else
                case "$reason" in
                    *"another copy of Google Chrome"*)
                        advice="The night run needs Chrome to itself: close the other copy of Chrome (usually a test browser a program opened)." ;;
                    *"Google Chrome is not running"*)
                        advice="Leave Chrome open at night." ;;
                    *)
                        advice="Leave Chrome open with View > Developer > Allow JavaScript from Apple Events on." ;;
                esac
                status alert chrome stop "Night run stopped: Chrome" "$reason.$tried $advice $next"
            fi ;;
        error)
            status alert error warn "Night run stopped" "$reason. $next" ;;
    esac
}

# ---------------------------------------------------------------- deep dive / fix sessions
claude_session() {   # claude_session MAX_MIN OUTFILE PROMPT [CLAUDE ARGS...]
    local max="$1" out="$2" prompt="$3" rc
    shift 3
    if [ ! -x "$CLAUDE_BIN" ]; then
        log "Claude CLI not found ($CLAUDE_BIN) — skipping the session"
        return 127
    fi
    guarded $((max * 60)) "$CLAUDE_BIN" -p "$prompt" --permission-mode auto --permission-prompts none \
        --output-format json "$@" > "$out" 2>> "$NIGHT_LOG"
    rc=$?
    log "Claude session ended (exit $rc): $(/usr/bin/python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1])); print(str(d.get("result") or "")[-300:].replace("\n", " "))
except Exception as e: print("no result:", e)' "$out" 2>/dev/null)"
    return $rc
}

# Research one run's zero-contact venues, save the finds, push. Runs in the background.
code_dirty() { git status --porcelain --untracked-files=no -- '*.sh' '*.py' '*.js' 'tests' | awk '{print $2}' | sort; }

dive_run() {
    local rid="$1" saved pre post f
    log "Deep dive ($rid): researching zero-contact venues"
    pre=$(code_dirty)
    claude_session "$DEEPDIVE_MAX_MIN" "$RUNS_DIR/$rid.deepdive-session.json" \
        "Night deep dive, phase RESEARCH, RUN_ID=$rid. Follow $SCRIPT_DIR/NIGHT_DEEPDIVE.md (sections 'Hard rules' and '1. Research'). Do NOT do the code-fix or taste-review steps now: another session does them after the last run, and a pipeline may be running right now, so do not edit any code. Working directory: $SCRIPT_DIR. Now: $(date '+%Y-%m-%d %H:%M')."
    # Research never edits code: put back anything it changed anyway
    post=$(code_dirty)
    for f in $(comm -13 <(echo "$pre") <(echo "$post")); do
        log "Deep dive ($rid) changed $f — restoring the committed version"
        git checkout -- "$f"
    done
    if [ -s "$RUNS_DIR/$rid.deepdive.json" ]; then
        saved=$(/usr/bin/python3 "$SCRIPT_DIR/night_save.py" "$rid" 2>&1 | tail -1)
        log "Deep dive ($rid) saved: $saved"
        local sv rv
        sv=$(printf '%s' "$saved" | sed -nE 's/.*saved=([0-9]+).*/\1/p')
        rv=$(printf '%s' "$saved" | sed -nE 's/.*venues_rescued=([0-9]+).*/\1/p')
        status run "$rid" "rescued_contacts=${sv:-0}" "rescued_venues=${rv:-0}" "deep_dive=done"
    else
        log "Deep dive ($rid): no findings file — nothing saved"
        status run "$rid" "deep_dive=no_findings"
    fi
    git_sync "Night deep dive $rid: zero-contact venues re-researched" night_status.json \
        "$RUNS_DIR/$rid.deepdive.json" "$RUNS_DIR/$rid.deepdive-saved.json" "$RUNS_DIR/$rid.deepdive.done" \
        "$RUNS_DIR/$rid.misses.jsonl" "$RUNS_DIR/$rid.zero.json"
}

start_dive() {   # start_dive RUN_ID — background; one Claude session at a time
    local rid="$1" line
    wait_dive
    apply_websites wait
    line=$(/usr/bin/python3 "$SCRIPT_DIR/night_zero.py" "$rid" 2>&1 | tail -1)
    log "Zero-contact check: $line"
    if ! /usr/bin/python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("venues") else 1)' \
         "$RUNS_DIR/$rid.zero.json" 2>/dev/null; then
        log "No zero-contact venues left to research in $rid"
        return 0
    fi
    dive_run "$rid" &
    DIVE_PID=$!
    DIVE_RID="$rid"
    local pending
    pending="$(state_get fix_pending)"
    case " $pending " in *" $rid "*) ;; *) state_set fix_pending "$pending $rid" ;; esac
}

wait_dive() {
    [ -n "$DIVE_PID" ] || return 0
    log "Waiting for the deep dive of $DIVE_RID to finish"
    wait "$DIVE_PID" 2>/dev/null
    DIVE_PID=""
    DIVE_RID=""
}

# Code fixes for what the pipeline missed, once no pipeline runs. Reverts anything broken.
fix_session() {
    local runs head_before rc
    runs="$(state_get fix_pending)"
    [ -n "$runs" ] || { log "No runs waiting for a fix session"; return 0; }
    if [ "$(hhmm)" -gt "$FIX_LATEST" ] && [ "$MODE" = "night" ]; then
        log "Too late for the fix session ($(hhmm) > $FIX_LATEST) — it runs next night"
        return 0
    fi
    if [ -d "$PIPE_LOCK" ]; then
        log "A pipeline is running — no code changes now; the fix session runs next night"
        return 0
    fi
    # Someone's uncommitted code (Alex, another session) is never mixed with night fixes
    local pre_dirty
    pre_dirty=$(git status --porcelain --untracked-files=no -- '*.sh' '*.py' '*.js' 'tests' | awk '{print $2}')
    if [ -n "$pre_dirty" ]; then
        log "Uncommitted code changes in the tree ($(echo $pre_dirty)) — skipping the fix session so they aren't touched; it runs next night"
        return 0
    fi
    head_before=$(git rev-parse HEAD)
    log "Fix session for: $runs"
    claude_session "$FIX_MAX_MIN" "$RUNS_DIR/night-$(date +%Y%m%d).fix-session.json" \
        "Night deep dive, phase FIX, RUN_IDS=\"$runs\". Follow $SCRIPT_DIR/NIGHT_DEEPDIVE.md: 'Hard rules', '2. Fix what the pipeline missed' for the misses in reports/runs/<RUN_ID>.misses.jsonl of those runs (on_venue_site true first), '3. Taste review', and '4. Summary' written to reports/runs/night-$(date +%Y%m%d).fix-summary.json. Working directory: $SCRIPT_DIR. Now: $(date '+%Y-%m-%d %H:%M')."
    rc=$?
    # The tree must be clean and healthy whatever the session did
    local dirty
    dirty=$(git status --porcelain --untracked-files=no -- '*.sh' '*.py' '*.js' 'tests' | awk '{print $2}')
    if [ -n "$dirty" ]; then
        log "Fix session left uncommitted code changes — reverting: $(echo $dirty)"
        git checkout -- $dirty
    fi
    if [ "$(git rev-parse HEAD)" != "$head_before" ]; then
        if health_check; then
            local n
            n=$(git rev-list --count "$head_before..HEAD")
            log "Fix session committed $n change(s); health check passed"
            status note "$(fix_note)"
        else
            log "Health check FAILED after the fix session — reverting its commits"
            git revert --no-edit "$head_before..HEAD" >/dev/null 2>&1 || { git revert --abort 2>/dev/null; git reset -q --hard "$head_before"; }
            status alert error warn "A night code fix was undone" "The scraper change from last night broke a check, so it was reverted. Nothing else changed."
        fi
    fi
    state_set fix_pending ""
    git_sync "Night fix session: taste review + status" night_status.json taste_notes.md taste_venues.txt \
        reports/taste_review_marker.json "$RUNS_DIR/night-$(date +%Y%m%d).fix-summary.json"
    return $rc
}

fix_note() {
    /usr/bin/python3 - "$RUNS_DIR/night-$(date +%Y%m%d).fix-summary.json" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("note") or f"{len(d.get('fixes') or [])} scraper fix(es) tonight")
except Exception:
    print("Scraper fixes committed tonight")
PYEOF
}

health_check() {   # every script parses, embedded python compiles, offline crawler tests pass
    local f ok=0
    for f in *.sh; do bash -n "$f" || { log "bash -n failed: $f"; ok=1; }; done
    for f in *.py; do /usr/bin/python3 -m py_compile "$f" 2>/dev/null || { log "py_compile failed: $f"; ok=1; }; done
    /usr/bin/python3 tests/check_heredocs.py pipeline.sh postcheck.sh build_batch.sh >/dev/null 2>&1 || { log "check_heredocs failed"; ok=1; }
    bash tests/site_discovery_tests.sh >/dev/null 2>&1 || { log "site_discovery_tests failed"; ok=1; }
    bash tests/google_guard_tests.sh >/dev/null 2>&1 || { log "google_guard_tests failed"; ok=1; }
    return $ok
}

# ---------------------------------------------------------------- missing websites
# Alex, Oct 1 2026: "you run discovery here in terminal and then the rest in chrome". The
# old lookup searched Google in Chrome at 01:00, ~20 searches in 5 minutes, and Google's
# CAPTCHA then blocked the pipeline's searches too: it ended the Sep 30 and Oct 1 nights.
# Now Claude looks the websites up with WebSearch in the background while Chrome does the
# runs, and backfill_websites.sh checks and saves its URLs (plain HTTP) between runs, so
# no venue changes under a running pipeline.
WEB_PID=""
WEB_DONE=1
WEB_LIST="$RUNS_DIR/websites-$(date +%Y%m%d).list.json"
WEB_FOUND="$RUNS_DIR/websites-$(date +%Y%m%d).json"
start_websites() {
    local n
    log "Missing websites: listing up to $BACKFILL_LIMIT venues"
    if ! guarded 600 ./backfill_websites.sh --limit "$BACKFILL_LIMIT" --list-json "$WEB_LIST" >> "$NIGHT_LOG" 2>&1; then
        log "backfill_websites.sh --list-json failed — no website lookups tonight"
        return 0
    fi
    n=$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("venues") or []))' "$WEB_LIST" 2>/dev/null)
    if [ "${n:-0}" -eq 0 ]; then
        log "No venues need a website"
        return 0
    fi
    rm -f "$WEB_FOUND"
    log "Missing websites: Claude looks up $n in the terminal (WebSearch, no Chrome) while Chrome does the runs"
    claude_session "$WEBSITES_MAX_MIN" "$RUNS_DIR/websites-$(date +%Y%m%d).session.json" \
        "Night website research. Follow $SCRIPT_DIR/NIGHT_WEBSITES.md with LIST=\"$WEB_LIST\" and OUT=\"$WEB_FOUND\". Working directory: $SCRIPT_DIR. Now: $(date '+%Y-%m-%d %H:%M')." \
        --disallowedTools "mcp__claude-in-chrome" "Bash(osascript:*)" "Bash(open:*)" &
    WEB_PID=$!
    WEB_DONE=0
}

apply_websites() {   # apply_websites [wait] — save the research's websites once it's done
    [ "$WEB_DONE" = 1 ] && return 0
    if kill -0 "$WEB_PID" 2>/dev/null; then
        [ "${1:-}" = "wait" ] || return 0
        log "Waiting for the website research to finish"
    fi
    wait "$WEB_PID" 2>/dev/null
    WEB_DONE=1
    if ! /usr/bin/python3 -m json.tool "$WEB_FOUND" >/dev/null 2>&1; then
        log "Website research left no readable findings ($WEB_FOUND) — nothing to save"
        return 0
    fi
    log "backfill_websites.sh --candidates --apply (check + save the websites Claude found)"
    guarded 1800 ./backfill_websites.sh --candidates "$WEB_FOUND" --apply >> "$NIGHT_LOG" 2>&1 ||
        log "backfill_websites.sh --candidates exited $? — going on"
    git_sync "Night websites: missing websites looked up in the terminal" "$WEB_LIST" "$WEB_FOUND"
}

# ---------------------------------------------------------------- one run
# What made a run fail: preflight's own FAIL lines (not its "aborting" summary), else the
# last ERROR/FAIL line. Only the log's tail, so a resumed run's older lines don't count.
run_fail_reason() {
    local r
    r=$(tail -n 80 "$1" 2>/dev/null | grep -E '^PREFLIGHT FAIL: ' | grep -vE '^PREFLIGHT FAIL: [0-9]+ check\(s\) failed' |
        sed 's/^PREFLIGHT FAIL: //' | tail -3 | paste -s -d ';' - | sed 's/;/; /g')
    [ -n "$r" ] || r=$(tail -n 80 "$1" 2>/dev/null | grep -E 'ERROR|FAIL' | tail -1)
    printf '%s' "${r:0:240}"
}

LAST_RID=""
LAST_STOP=""
LAST_MODE=""
do_run() {   # returns 0 finished, 3 stopped (LAST_STOP has why), 4 pool empty, 1 error
    local rid resume attempts rc mode
    resume="$(state_get resume)"
    if [ -n "$resume" ]; then
        rid="$resume"; mode="--resume"
        log "Resuming $rid (left unfinished: $(state_get resume_reason))"
    else
        rid="run-$(date +%Y%m%d-%H%M)"; mode="--run"
        local n=2
        while [ -e "$RUNS_DIR/$rid.plan" ] || [ -e "$RUNS_DIR/$rid.jsonl" ] || [ -e "$RUNS_DIR/$rid.log" ]; do
            rid="run-$(date +%Y%m%d-%H%M)-$n"; n=$((n + 1))
        done
        log "New run $rid of $RUN_SIZE venues"
    fi
    LAST_RID="$rid"
    LAST_STOP=""
    LAST_MODE="$mode"
    LAST_STARTED=1
    LAST_RESUMABLE=1
    status run "$rid" "outcome=running" "started=$(date +%H:%M)"
    status_push "$rid started"
    # Output goes to the run's own log (pipeline.sh sees that and doesn't tee it twice)
    if [ "$mode" = "--run" ]; then
        RUN_ID="$rid" RUN_DEADLINE="$(deadline_epoch)" ./pipeline.sh --run "$RUN_SIZE" >> "$RUNS_DIR/$rid.log" 2>&1
    else
        RUN_ID="$rid" RUN_DEADLINE="$(deadline_epoch)" ./pipeline.sh --resume "$rid" >> "$RUNS_DIR/$rid.log" 2>&1
    fi
    rc=$?
    log "pipeline.sh $mode $rid exited $rc — $(grep -E '^\[RUN\] (Plan finished|STOPPED)|build_batch.sh found no eligible' "$RUNS_DIR/$rid.log" | tail -1)"
    if [ "$mode" = "--run" ] && [ ! -f "$RUNS_DIR/$rid.plan" ]; then
        if [ "$rc" = 0 ] && grep -q "found no eligible venues" "$RUNS_DIR/$rid.log"; then
            status run "$rid" "outcome=no venues left to run" "ended=$(date +%H:%M)"
            return 4
        fi
        local why
        why=$(run_fail_reason "$RUNS_DIR/$rid.log")
        LAST_STOP="the run could not start (pipeline.sh exit $rc): $why"
        LAST_STARTED=0
        LAST_RESUMABLE=0
        status run "$rid" "outcome=could not start: ${why:0:140}" "ended=$(date +%H:%M)"
        return 1
    fi
    status clear-alert pool
    local stats
    stats=$(/usr/bin/python3 "$SCRIPT_DIR/night_zero.py" "$rid" --stats 2>/dev/null)
    # shellcheck disable=SC2086
    [ -n "$stats" ] && status run "$rid" $stats
    if [ "$rc" = 0 ]; then
        state_set resume ""; state_set resume_reason ""; state_set resume_attempts ""
        status run "$rid" "outcome=finished" "ended=$(date +%H:%M)"
        return 0
    fi
    LAST_STOP=$(head -1 "$RUNS_DIR/$rid.stopped" 2>/dev/null)
    case "$LAST_STOP" in
        "preflight failed"*) LAST_STOP="$LAST_STOP: $(run_fail_reason "$RUNS_DIR/$rid.log")" ;;
        "") LAST_STOP="pipeline.sh exited $rc: $(run_fail_reason "$RUNS_DIR/$rid.log")" ;;
    esac
    if [ ! -f "$RUNS_DIR/$rid.jsonl" ]; then
        # Nothing was registered: nothing to resume, the plan's venues are still in the pool
        state_set resume ""; state_set resume_reason ""; state_set resume_attempts ""
        LAST_STARTED=0
        LAST_RESUMABLE=0
        status run "$rid" "outcome=could not start: ${LAST_STOP:0:140}" "ended=$(date +%H:%M)"
        return 1
    fi
    classify_stop "$LAST_STOP"
    attempts="$(state_get resume_attempts)"; attempts=${attempts:-0}
    # Chrome being busy or closed isn't the run's fault: only other stops count toward dropping it
    case "$STOP_KIND" in deadline|chrome) ;; *) attempts=$((attempts + 1)) ;; esac
    if [ "$attempts" -gt "$MAX_RESUMES" ]; then
        log "Run $rid stopped $attempts times ($LAST_STOP) — dropping it; venues it never started go back to the pool"
        LAST_RESUMABLE=0
        state_set resume ""; state_set resume_reason ""; state_set resume_attempts ""
        status run "$rid" "outcome=dropped after $attempts stops: ${LAST_STOP:0:120}" "ended=$(date +%H:%M)"
        status alert error warn "A run was dropped" "Run $rid kept stopping ($LAST_STOP). The next night starts a fresh run."
    else
        state_set resume "$rid"; state_set resume_reason "$LAST_STOP"; state_set resume_attempts "$attempts"
        if [ "$STOP_KIND" = "deadline" ]; then
            status run "$rid" "outcome=paused at the ${NIGHT_CUTOFF:0:2}:${NIGHT_CUTOFF:2:2} cutoff; finishes next night" "ended=$(date +%H:%M)"
        else
            status run "$rid" "outcome=stopped: ${LAST_STOP:0:140}" "ended=$(date +%H:%M)"
        fi
    fi
    [ "$rc" = 3 ] && return 3
    return 1
}

run_files() {   # the run's own small files, for the commit
    local rid="$1"
    ls "$RUNS_DIR/$rid".batch*.json "$RUNS_DIR/$rid".batch*.done 2>/dev/null
    echo "$RUNS_DIR/$rid.jsonl" "$RUNS_DIR/$rid.log" "$RUNS_DIR/$rid.plan" "$RUNS_DIR/$rid.stopped"
    ls -d "$RUNS_DIR/plans/plan-$rid" 2>/dev/null
}

# ================================================================= main
if [ "$MODE" = "check" ]; then
    rc=0
    zb_check || rc=1
    apollo_check || rc=1
    [ -x "$CLAUDE_BIN" ] && log "Claude CLI: $("$CLAUDE_BIN" --version 2>/dev/null)" || { log "Claude CLI missing"; rc=1; }
    log "Cutoff ${NIGHT_CUTOFF}, runs of $RUN_SIZE, up to $NIGHT_MAX_RUNS a night; resume pending: $(state_get resume)"
    [ -f .night_off ] && log "Kill switch .night_off is ON — nights are skipped"
    exit $rc
fi

if [ "$MODE" = "dive" ]; then
    case "$DIVE_ONLY" in ''|*[!A-Za-z0-9._-]*) echo "usage: $0 --dive RUN_ID"; exit 2 ;; esac
    [ -f "$RUNS_DIR/$DIVE_ONLY.batch1.json" ] || { log "No batches for $DIVE_ONLY in $RUNS_DIR"; exit 1; }
    log "================ Deep dive only: $DIVE_ONLY ================"
    start_dive "$DIVE_ONLY"
    wait_dive
    log "================ Deep dive done $(date '+%H:%M') ================"
    exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    other=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        log "Another night run is going (PID $other) — exiting"
        exit 0
    fi
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" || exit 1
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rmdir "$GIT_LOCK" 2>/dev/null; rm -rf "$LOCK_DIR"' EXIT

log "================ Night run $(date '+%Y-%m-%d %H:%M') (mode $MODE) ================"

now=$(hhmm)
if [ "$MODE" = "night" ] && { [ "$now" -lt "$NIGHT_START_EARLIEST" ] || [ "$now" -gt "$NIGHT_START_LATEST" ]; }; then
    log "Started at $now, outside the ${NIGHT_START_EARLIEST}-${NIGHT_START_LATEST} window (the Mac was asleep or off at 1:00) — skipping tonight"
    status alert asleep warn "Last night's run didn't happen" "The Mac was asleep or off at 1:00 (it woke at $(date +%H:%M)), so the run was skipped to keep Chrome free. Leave it plugged in with the lid open."
    status_push "missed night"
    exit 0
fi
if [ -f "$SCRIPT_DIR/.night_off" ]; then
    log "Kill switch .night_off is on — skipping"
    status note "Night runs are paused (.night_off)."
    status_push "paused"
    exit 0
fi
if [ -d "$PIPE_LOCK" ] && [ -n "$(cat "$PIPE_LOCK/pid" 2>/dev/null)" ] && kill -0 "$(cat "$PIPE_LOCK/pid")" 2>/dev/null; then
    log "A pipeline run is already going (PID $(cat "$PIPE_LOCK/pid")) — skipping tonight"
    exit 0
fi

status start
if ! zb_check && ! { log "Checking ZeroBounce again in 60s (a network blip looks the same)"; sleep 60; zb_check; }; then
    status alert zerobounce stop "Night runs paused: ZeroBounce" "$ZB_DETAIL"
    status finish stopped
    status_push "stopped (ZeroBounce)"
    exit 0
fi
if ! apollo_check; then
    status alert apollo stop "Night runs paused: Apollo credits" "Apollo has $APOLLO_LEFT credits left (the floor is $APOLLO_MIN_CREDITS). Top up and the next night starts again."
    status finish stopped
    status_push "stopped (Apollo)"
    exit 0
fi
status clear-alert zerobounce apollo asleep chrome error
log "Credits OK. Cutoff ${NIGHT_CUTOFF:0:2}:${NIGHT_CUTOFF:2:2} ($(minutes_left) min from now)"
. "$SCRIPT_DIR/google_guard.sh"
google_cooling && log "Google is still blocking searches from an earlier CAPTCHA (until $GOOGLE_RETRY_AT) — the scripts skip Google until then"

# Emails saved as unverified when ZeroBounce ran out get their real verdict now
if /usr/bin/python3 -c 'import sys' && [ -x ./reverify.sh ]; then
    log "Re-checking contacts saved as unverified"
    guarded 900 ./reverify.sh --unverified --limit 60 >> "$NIGHT_LOG" 2>&1 || log "reverify.sh exited $? (see above)"
fi
# Every venue in a sweep write-up (sweep_*.md) must be on the sheet and marked as a sweep
# find (Alex, Sep 29: "make sure you can access every place in the sweeps")
log "import_sweep_files.py --apply (sweep write-ups -> sheet)"
guarded 1200 /usr/bin/python3 import_sweep_files.py --apply >> "$NIGHT_LOG" 2>&1 || log "import_sweep_files.py exited $? — going on"
# Venues saved without a website (sweep finds too, Alex Sep 29: "everything on the sweep
# should be able to be used") get one from Claude's WebSearch, in the background, never
# Chrome (see start_websites)
start_websites
# Good sweep / discovery finds become runnable (plain HTTP, never Chrome)
log "verify_pool.py --apply (promote verified needs_review venues)"
guarded 1200 /usr/bin/python3 verify_pool.py --apply --limit 400 >> "$NIGHT_LOG" 2>&1 || log "verify_pool.py exited $? — going on"
# ...and untouched sweep finds whose domain doesn't spell their name, once their page names them
guarded 900 /usr/bin/python3 verify_pool.py --vouch-sweep-sites --apply --limit 300 >> "$NIGHT_LOG" 2>&1 || log "verify_pool.py --vouch-sweep-sites exited $? — going on"
# Venues whose LinkedIn search hit the wall or came back empty (linkedin_pending, the app's
# "LinkedIn Quota Reset" card) get it again a day later, once LinkedIn has let up. Alex,
# Sep 30 2026: "will you do this on the outreach run tonight?" The retry stops at a wall
# and leaves the rest pending for the next night.
log "pipeline.sh --linkedin-retry (venues LinkedIn skipped before, up to $LI_RETRY_MAX_MIN min)"
guarded $((LI_RETRY_MAX_MIN * 60)) ./pipeline.sh --linkedin-retry >> "$NIGHT_LOG" 2>&1 || log "pipeline.sh --linkedin-retry exited $? — going on"

new_runs=0
night_state="done"
while [ "$new_runs" -lt "$NIGHT_MAX_RUNS" ]; do   # a resumed run, or one that couldn't start, doesn't count
    left=$(minutes_left)
    if [ "$left" -lt "$MIN_RUN_WINDOW_MIN" ]; then
        log "Only $left min before the cutoff — no more runs tonight"
        break
    fi
    apply_websites   # the research's websites, if it's done (never during a run)
    do_run
    rc=$?
    [ "$LAST_MODE" = "--run" ] && [ "$LAST_STARTED" = 1 ] && new_runs=$((new_runs + 1))
    if [ "$rc" = 4 ]; then
        log "No eligible venues left — the pool needs a sweep"
        status alert pool warn "Out of venues to run" "Every venue that passes the filters has been worked. A sweep of a new city refills the pool."
        git_sync "Night: pool empty" night_status.json
        break
    fi
    g_blocked=$(grep -c '\[GOOGLE BLOCKED\]' "$RUNS_DIR/$LAST_RID.log" 2>/dev/null)
    [ "${g_blocked:-0}" -gt 0 ] && log "Google blocked or skipped $g_blocked search(es) in $LAST_RID (CAPTCHA cooldown) — the run went on without them"
    run_stats=$(/usr/bin/python3 "$SCRIPT_DIR/night_zero.py" "$LAST_RID" --stats 2>/dev/null | tr ' ' ',')
    # shellcheck disable=SC2046
    git_sync "Night run $LAST_RID: ${run_stats:-${LAST_STOP:0:120}}" night_status.json $(run_files "$LAST_RID")
    [ -f "$RUNS_DIR/$LAST_RID.jsonl" ] && start_dive "$LAST_RID"
    [ "$rc" = 0 ] && continue
    classify_stop "$LAST_STOP"
    if [ "$STOP_KIND" = "deadline" ]; then
        log "Cutoff reached — $LAST_RID finishes next night"
        break
    fi
    # Chrome trouble often passes (another copy of Chrome, a hung tab): wait and try again
    # before giving up the night. So does Google's CAPTCHA: the pipeline waits that out by
    # itself now (google_guard.sh), so this only catches a run it still stopped (Oct 1 2026:
    # a Google block ended the night at 01:26 with 6.5 hours left).
    retry_wait="$CHROME_RETRY_WAIT_S"
    google_block "$LAST_STOP" && retry_wait="$GOOGLE_RETRY_WAIT_S"
    if [ "$STOP_KIND" = "chrome" ] && [ "$CHROME_TRIED" -lt "$CHROME_RETRIES" ] &&
       [ $(( $(minutes_left) - retry_wait / 60 )) -ge "$MIN_RUN_WINDOW_MIN" ]; then
        CHROME_TRIED=$((CHROME_TRIED + 1))
        log "Chrome problem ($LAST_STOP) — trying again in $((retry_wait / 60)) min ($CHROME_TRIED of $CHROME_RETRIES)"
        sleep "$retry_wait"
        continue
    fi
    log "Run stopped: $LAST_STOP"
    alert_for_stop "$LAST_RID" "$LAST_STOP"
    night_state="stopped"
    break
done

apply_websites wait
wait_dive
fix_session
status note "$(/usr/bin/python3 - "$SCRIPT_DIR/night_status.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
runs = [r for r in (d.get("night") or {}).get("runs") or [] if int(r.get("venues") or 0) > 0]
s = lambda k: sum(int(r.get(k) or 0) for r in runs)
if not runs:
    print("No venues ran tonight")
    sys.exit(0)
parts = [f"{len(runs)} run{'s' if len(runs) != 1 else ''}", f"{s('processed')} venues",
         f"{s('with_contacts')} with contacts", f"{s('new_contacts')} new contacts"]
if s("rescued_contacts"):
    parts.append(f"{s('rescued_contacts')} more from the deep dive")
print(" · ".join(parts))
PYEOF
)"
status finish "$night_state"
status_push "night finished"
log "================ Night done $(date '+%H:%M') ================"
exit 0
