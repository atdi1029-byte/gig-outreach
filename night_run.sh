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
#   ./night_run.sh --burn     the 24/7 burn (Alex, Nov 6 2026: "do the whole outreach flow on
#                             repeat until my credits run out and then not do the outreach stuff
#                             for a couple months", "which ever runs out first ill probably stop").
#                             Rounds of BURN_RUN_SIZE (25) back to back, any hour, .night_off
#                             ignored. After each round a Claude session audits EVERY venue of it
#                             (not only the zeros) while the next round runs; every BURN_FIX_EVERY
#                             (4) rounds the fix session turns zero-contact misses into scraper
#                             fixes and the pool prep runs again. Pause: touch .burn_pause (stops
#                             before the next batch; rm it and the same run picks up where it
#                             stopped). ZeroBounce or Apollo out of credits ends it for good:
#                             .burn_done + app alert, and night runs stay off. Start it in
#                             Terminal: open burn_run.command
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
#   5. the rest of the night goes to the family tree (Alex, Oct 11 2026: "if we have time
#      after 1 run of 50 and fixing itself it uses its energy on the family tree", then "after
#      the email spend what ever time is left on ancestry stuff", "allow it"): one Claude session (sonnet, Claude in
#      Chrome, FamilyTree/NIGHT_ANCESTRY.md) works Ancestry read-only until 65 min before the
#      cutoff (minus the update's time); then one Claude session without Chrome
#      (FamilyTree/LEAD_UPDATE.md, ~45 min, done by 07:45) checks, merges and publishes.
#      Codex runs 24/7 on its own (Alex, Oct 11: "i want codex to be running 24/7"). Codex-1 is the
#      one in Chrome, so it pauses while the email work runs: CODEX_PAUSE exists from the start of
#      the night until the email work is done (FamilyTree/tools/codex_worker.sh waits on it).
# A stop (credits, preflight) ends the email part of the night; the app shows why, and the
# family tree shift still runs. A Chrome stop is first
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
    --burn) MODE="burn" ;;
    "") ;;
    *) echo "usage: $0 [--check|--force|--dive RUN_ID|--burn]"; exit 2 ;;
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
NIGHT_MAX_RUNS="${NIGHT_MAX_RUNS:-2}"   # Alex, Nov 6 2026: "like 1 or 2 email runs"; the family tree is tabled
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
BURN_FIX_EVERY="${BURN_FIX_EVERY:-4}"          # burn: fix session + pool prep every N rounds
BURN_RETRIES="${BURN_RETRIES:-6}"              # burn: non-credit stops tried again this many times in a row
BURN_PAUSE="$SCRIPT_DIR/.burn_pause"
BURN_DONE="$SCRIPT_DIR/.burn_done"
if [ "$MODE" = "burn" ]; then
    RUN_SIZE="${BURN_RUN_SIZE:-25}"
    NIGHT_MAX_RUNS=1000000
    DEEPDIVE_MAX_MIN="${BURN_AUDIT_MAX_MIN:-150}"   # a full audit of 25 venues, not only the zeros
    # .env's 400-a-day ZeroBounce cap would stop the burn every day; the balance floor still holds
    export ZB_MAX_PER_DAY="${BURN_ZB_MAX_PER_DAY:-5000}"
fi
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo /usr/local/bin/claude)}"
RUNS_DIR="$SCRIPT_DIR/reports/runs"
STATE="$RUNS_DIR/night-state.json"
NIGHT_LOG="$RUNS_DIR/night-$(date +%Y%m%d).log"
[ "$MODE" = "burn" ] && NIGHT_LOG="$RUNS_DIR/burn-$(date +%Y%m%d-%H%M).log"
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
state_set() {   # state_set KEY VALUE   (VALUE "" deletes; a KEY ending in _pending takes a space list)
    /usr/bin/python3 - "$STATE" "$1" "$2" <<'PYEOF'
import json, os, sys
p, k, v = sys.argv[1:4]
try:
    d = json.load(open(p))
except (OSError, ValueError):
    d = {}
if k.endswith("_pending"):
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
pending_add() { local cur; cur="$(state_get "$1")"; case " $cur " in *" $2 "*) ;; *) state_set "$1" "$cur $2" ;; esac; }
pending_del() { local cur x out=""; cur="$(state_get "$1")"; for x in $cur; do [ "$x" = "$2" ] || out="$out $x"; done; state_set "$1" "$out"; }

deadline_epoch() {   # today's NIGHT_CUTOFF (a night always starts after midnight); the burn has none
    [ "$MODE" = "burn" ] && { echo $(( $(date +%s) + 86400 )); return; }
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
ZB_REASON=""
zb_check() {   # 0 = ZeroBounce usable. Sets ZB_DETAIL to a plain explanation otherwise.
    local out allowed reason credits raw
    out=$(/usr/bin/python3 "$SCRIPT_DIR/zerobounce_guard.py" budget --run-id "night-check-$$" 2>/dev/null)
    allowed=$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("allowed"), d.get("reason"), d.get("credits_remaining"))' 2>/dev/null)
    read -r allowed reason credits <<< "$allowed"
    ZB_REASON="$reason"
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
        "paused by Alex"*) STOP_KIND="pause" ;;
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

# ---------------------------------------------------------------- family tree after the outreach
FAMILY_TREE="${FAMILY_TREE:-$HOME/Documents/Code/Claude/FamilyTree}"
CODEX_PAUSE="$SCRIPT_DIR/.codex1_pause"   # Codex-1 (Chrome) waits while this exists
codex_pause() {   # Chrome must be the email run's alone: pause Codex-1 and end its current session
    local pidf="$FAMILY_TREE/logs/workers/Codex-1.pid" sup c
    date '+%Y-%m-%d %H:%M' > "$CODEX_PAUSE"
    sup=$(cat "$pidf" 2>/dev/null)
    if [ -n "$sup" ] && kill -0 "$sup" 2>/dev/null; then
        for c in $(pgrep -P "$sup" 2>/dev/null); do kill $(proc_tree "$c") 2>/dev/null; done
        log "Codex-1 paused for the email run (its current session ended; the supervisor waits)"
    fi
}
family_tree_shift() {   # after the email work: Ancestry (Claude, Chrome), then the lead update (Claude, no Chrome)
    local ft="$FAMILY_TREE"
    rm -f "$CODEX_PAUSE"
    log "Family tree: tabled (Alex, Nov 6 2026), no Ancestry session or lead update"; return 0
    [ "$MODE" = "night" ] || { log "Family tree: only on a real night (mode $MODE) — skipped"; return 0; }
    # ...then Ancestry: one read-only Claude session in Chrome, leaving time for the lead update
    local upd_min=45 anc_left anc_out upd_left ymd
    ymd=$(date -v+1d +%Y-%m-%d)   # the lead names a night file after the next day (11 Oct evening -> 2026-10-12)
    anc_left=$(( $(minutes_left) - 15 - upd_min ))
    if [ ! -f "$ft/NIGHT_ANCESTRY.md" ]; then
        log "Family tree: no NIGHT_ANCESTRY.md - no Ancestry session"
    elif [ "$anc_left" -lt 20 ]; then
        log "Family tree: only $anc_left min for Ancestry - skipped"
    else
        anc_out="$ft/handoff/ancestry_night_$ymd.md"
        [ -e "$anc_out" ] && anc_out="$ft/handoff/ancestry_night_${ymd}_b.md"
        log "Family tree: Ancestry session (sonnet, Chrome) for up to $anc_left min -> $anc_out"
        ( cd "$ft" && claude_session "$anc_left" "$RUNS_DIR/night-$(date +%Y%m%d).ancestry-session.json" \
            "Night Ancestry run for Alex's family tree. Follow $ft/NIGHT_ANCESTRY.md exactly (hard rules first). Write your night file to $anc_out. Working directory: $ft. Now: $(date '+%Y-%m-%d %H:%M'); write the STOP POINT / RESUME LIST and stop by $(date -r $(( $(deadline_epoch) - (20 + upd_min) * 60 )) '+%H:%M')." \
            --model sonnet --chrome )
    fi
    # ...and the lead update: no Chrome, ~45 min, killed by 07:45; skipped if Ancestry overran
    upd_left=$(( $(minutes_left) - 15 ))
    [ "$upd_left" -gt "$upd_min" ] && upd_left=$upd_min
    if [ ! -f "$ft/LEAD_UPDATE.md" ]; then
        log "Family tree: no LEAD_UPDATE.md - no lead update"
    elif [ "$upd_left" -lt 15 ]; then
        log "Family tree: only $upd_left min left - lead update skipped tonight"
    else
        log "Family tree: lead update (sonnet, no Chrome) for up to $upd_left min"
        ( cd "$ft" && claude_session "$upd_left" "$RUNS_DIR/night-$(date +%Y%m%d).lead-update-session.json" \
            "Nightly lead update for Alex's family tree. Follow $ft/LEAD_UPDATE.md exactly. Do NOT use Chrome or any browser. Write handoff/lead_update_$(date +%Y-%m-%d).md. Working directory: $ft. Now: $(date '+%Y-%m-%d %H:%M'); finish by $(date -r $(( $(deadline_epoch) - 15 * 60 )) '+%H:%M')." \
            --model sonnet --disallowedTools 'mcp__claude-in-chrome__*' )
    fi
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

# Does Claude answer at all? A one-line haiku session; fails when Claude is out of credits,
# rate-limited or logged out (Alex, Nov 6 2026: his Claude plan ends in a couple of weeks)
claude_ok() {
    [ -x "$CLAUDE_BIN" ] || return 1
    guarded 180 "$CLAUDE_BIN" -p 'Reply with exactly: ok' --model haiku --output-format json \
        --permission-mode auto --permission-prompts none 2>/dev/null |
        /usr/bin/python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
    sys.exit(0 if not d.get("is_error") and "ok" in str(d.get("result") or "").lower() else 1)
except Exception:
    sys.exit(1)'
}

# The burn waits while Claude is out, so ZeroBounce and Apollo credits are never spent on
# rounds nobody audits; when Claude answers again, the audits it missed run first.
claude_wait() {
    log "Claude is out of credits (or not answering) — the burn waits, checking every 30 min"
    status alert claude stop "Outreach paused: Claude is out of credits" "The rounds wait so ZeroBounce and Apollo credits aren't spent on venues nobody audits. It checks every 30 minutes and goes on by itself when Claude works again."
    status_push "burn waiting for Claude"
    while ! claude_ok; do sleep 1800; done
    log "Claude answers again — catching up the audits it missed: $(state_get audit_pending)"
    status clear-alert claude
    status note "Outreach running again"
    status_push "Claude back"
    local rid
    for rid in $(state_get audit_pending); do
        start_dive "$rid"
        wait_dive
    done
}

# Research one run's zero-contact venues, save the finds, push. Runs in the background.
code_dirty() { git status --porcelain --untracked-files=no -- '*.sh' '*.py' '*.js' 'tests' | awk '{print $2}' | sort; }

dive_run() {
    local rid="$1" saved pre post f scope="" what="zero-contact venues"
    [ "$MODE" = "burn" ] && { scope=" FULL AUDIT (every venue of the run, see 'Burn: full audit')"; what="every venue (full audit)"; }
    log "Deep dive ($rid): researching $what"
    pre=$(code_dirty)
    claude_session "$DEEPDIVE_MAX_MIN" "$RUNS_DIR/$rid.deepdive-session.json" \
        "Night deep dive, phase RESEARCH$scope, RUN_ID=$rid. Follow $SCRIPT_DIR/NIGHT_DEEPDIVE.md (sections 'Hard rules' and '1. Research'). Do NOT do the code-fix or taste-review steps now: another session does them after the last run, and a pipeline may be running right now, so do not edit any code. Working directory: $SCRIPT_DIR. Now: $(date '+%Y-%m-%d %H:%M')."
    local drc=$?
    # Claude ran out mid-audit (or never started): what it wrote is saved below, the rest
    # of the run waits in audit_pending until Claude answers again (claude_wait)
    if { [ "$drc" != 0 ] || [ ! -s "$RUNS_DIR/$rid.deepdive.json" ]; } && ! claude_ok; then
        log "Deep dive ($rid): Claude is out — the audit of this run waits for it"
        pending_add audit_pending "$rid"
    else
        pending_del audit_pending "$rid"
    fi
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
    apply_repair wait
    local all=""
    [ "$MODE" = "burn" ] && all="--all"
    line=$(/usr/bin/python3 "$SCRIPT_DIR/night_zero.py" "$rid" $all 2>&1 | tail -1)
    log "Zero-contact check: $line"
    if ! /usr/bin/python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("venues") else 1)' \
         "$RUNS_DIR/$rid.zero.json" 2>/dev/null; then
        log "No zero-contact venues left to research in $rid"
        pending_del audit_pending "$rid"
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
    local tag="night-$(date +%Y%m%d)"
    [ "$MODE" = "burn" ] && tag="burn-$(date +%Y%m%d-%H%M)"   # several fix sessions a day
    log "Fix session for: $runs"
    claude_session "$FIX_MAX_MIN" "$RUNS_DIR/$tag.fix-session.json" \
        "Night deep dive, phase FIX, RUN_IDS=\"$runs\". Follow $SCRIPT_DIR/NIGHT_DEEPDIVE.md: 'Hard rules', '2. Fix what the pipeline missed' for the misses in reports/runs/<RUN_ID>.misses.jsonl of those runs (on_venue_site true first), '3. Taste review', and '4. Summary' written to reports/runs/$tag.fix-summary.json. Working directory: $SCRIPT_DIR. Now: $(date '+%Y-%m-%d %H:%M')."
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
            status note "$(fix_note "$RUNS_DIR/$tag.fix-summary.json")"
        else
            log "Health check FAILED after the fix session — reverting its commits"
            git revert --no-edit "$head_before..HEAD" >/dev/null 2>&1 || { git revert --abort 2>/dev/null; git reset -q --hard "$head_before"; }
            status alert error warn "A night code fix was undone" "The scraper change from last night broke a check, so it was reverted. Nothing else changed."
        fi
    fi
    if [ "$rc" != 0 ] && ! claude_ok; then
        log "Fix session: Claude is out — these runs keep waiting for a fix session: $runs"
    else
        state_set fix_pending ""
    fi
    git_sync "Night fix session: taste review + status" night_status.json taste_notes.md taste_venues.txt \
        reports/taste_review_marker.json "$RUNS_DIR/$tag.fix-summary.json"
    return $rc
}

fix_note() {   # fix_note SUMMARY_FILE
    /usr/bin/python3 - "$1" <<'PYEOF' 2>/dev/null
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

# ---------------------------------------------------------------- pool repair
# Nov 11 2026 (Alex: "did you fix this so next time we do sweeps it will show up?"): good venues the
# planner skips for bad data (query words as the city, chain homepages, geocodes in other states, never
# verified, or upscale but not European) get researched by Claude (NIGHT_REPAIR.md, WebSearch, no Chrome)
# and fixed by repair_pool.py, so they reach the queue instead of sitting there for months.
REPAIR_PID=""
REPAIR_DONE=1
REPAIR_LIMIT="${REPAIR_LIMIT:-60}"
REPAIR_MAX_MIN="${REPAIR_MAX_MIN:-60}"
start_repair() {
    local n stamp
    stamp=$(date +%Y%m%d-%H%M)
    REPAIR_LIST="$RUNS_DIR/repair-$stamp.list.json"
    REPAIR_FOUND="$RUNS_DIR/repair-$stamp.json"
    log "Pool repair: listing up to $REPAIR_LIMIT good venues stuck behind bad data"
    if ! guarded 1200 /usr/bin/python3 repair_pool.py list --out "$REPAIR_LIST" --limit "$REPAIR_LIMIT" >> "$NIGHT_LOG" 2>&1; then
        log "repair_pool.py list failed — no pool repair this time"
        return 0
    fi
    n=$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("venues") or []))' "$REPAIR_LIST" 2>/dev/null)
    if [ "${n:-0}" -eq 0 ]; then
        log "Pool repair: nothing stuck"
        return 0
    fi
    log "Pool repair: Claude researches $n venues in the terminal (WebSearch, no Chrome)"
    claude_session "$REPAIR_MAX_MIN" "$RUNS_DIR/repair-$stamp.session.json" \
        "Pool repair research. Follow $SCRIPT_DIR/NIGHT_REPAIR.md with LIST=\"$REPAIR_LIST\" and OUT=\"$REPAIR_FOUND\". Working directory: $SCRIPT_DIR. Now: $(date '+%Y-%m-%d %H:%M')." \
        --disallowedTools "mcp__claude-in-chrome" "Bash(osascript:*)" "Bash(open:*)" "Agent" "Task" &
    REPAIR_PID=$!
    REPAIR_DONE=0
}

apply_repair() {   # apply_repair [wait] — write the research's fixes once it's done (never during a run)
    [ "$REPAIR_DONE" = 1 ] && return 0
    if kill -0 "$REPAIR_PID" 2>/dev/null; then
        [ "${1:-}" = "wait" ] || return 0
        log "Waiting for the pool repair research to finish"
    fi
    wait "$REPAIR_PID" 2>/dev/null
    REPAIR_DONE=1
    if ! /usr/bin/python3 -m json.tool "$REPAIR_FOUND" >/dev/null 2>&1; then
        log "Pool repair left no readable findings ($REPAIR_FOUND) — nothing to save"
        return 0
    fi
    log "repair_pool.py apply (websites, cities, drive times, upscale ratings, non-venues dismissed)"
    guarded 3600 /usr/bin/python3 repair_pool.py apply "$REPAIR_FOUND" --list "$REPAIR_LIST" --apply >> "$NIGHT_LOG" 2>&1 ||
        log "repair_pool.py apply exited $? — going on"
    git_sync "Burn: pool repair (stuck venues researched and fixed)" "$REPAIR_LIST" "$REPAIR_FOUND"
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
    # Chrome being busy or closed isn't the run's fault, nor is Alex's pause: only other stops count toward dropping it
    case "$STOP_KIND" in deadline|chrome|pause) ;; *) attempts=$((attempts + 1)) ;; esac
    if [ "$attempts" -gt "$MAX_RESUMES" ]; then
        log "Run $rid stopped $attempts times ($LAST_STOP) — dropping it; venues it never started go back to the pool"
        LAST_RESUMABLE=0
        state_set resume ""; state_set resume_reason ""; state_set resume_attempts ""
        status run "$rid" "outcome=dropped after $attempts stops: ${LAST_STOP:0:120}" "ended=$(date +%H:%M)"
        status alert error warn "A run was dropped" "Run $rid kept stopping ($LAST_STOP). The next night starts a fresh run."
    else
        state_set resume "$rid"; state_set resume_reason "$LAST_STOP"; state_set resume_attempts "$attempts"
        if [ "$STOP_KIND" = "pause" ]; then
            status run "$rid" "outcome=paused by Alex; picks up where it stopped" "ended=$(date +%H:%M)"
        elif [ "$STOP_KIND" = "deadline" ]; then
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
trap 'rmdir "$GIT_LOCK" 2>/dev/null; rm -rf "$LOCK_DIR"; rm -f "$CODEX_PAUSE"' EXIT

log "================ Night run $(date '+%Y-%m-%d %H:%M') (mode $MODE) ================"

now=$(hhmm)
if [ "$MODE" = "night" ] && { [ "$now" -lt "$NIGHT_START_EARLIEST" ] || [ "$now" -gt "$NIGHT_START_LATEST" ]; }; then
    log "Started at $now, outside the ${NIGHT_START_EARLIEST}-${NIGHT_START_LATEST} window (the Mac was asleep or off at 1:00) — skipping tonight"
    status alert asleep warn "Last night's run didn't happen" "The Mac was asleep or off at 1:00 (it woke at $(date +%H:%M)), so the run was skipped to keep Chrome free. Leave it plugged in with the lid open."
    status_push "missed night"
    exit 0
fi
if [ "$MODE" = "burn" ] && [ -f "$BURN_DONE" ]; then
    log "The burn already ended ($(head -1 "$BURN_DONE")) — rm .burn_done to start another"
    exit 0
fi
if [ "$MODE" != "burn" ] && [ -f "$SCRIPT_DIR/.night_off" ]; then
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
codex_pause
if ! zb_check && ! { log "Checking ZeroBounce again in 60s (a network blip looks the same)"; sleep 60; zb_check; }; then
    status alert zerobounce stop "Night runs paused: ZeroBounce" "$ZB_DETAIL"
    status finish stopped
    status_push "stopped (ZeroBounce)"
    family_tree_shift   # Oct 12 2026: a credit stop skips the email, not the family tree (it lost the 12 Oct night)
    exit 0
fi
if ! apollo_check; then
    status alert apollo stop "Night runs paused: Apollo credits" "Apollo has $APOLLO_LEFT credits left (the floor is $APOLLO_MIN_CREDITS). Top up and the next night starts again."
    status finish stopped
    status_push "stopped (Apollo)"
    family_tree_shift
    exit 0
fi
status clear-alert zerobounce apollo asleep chrome error
log "Credits OK. Cutoff ${NIGHT_CUTOFF:0:2}:${NIGHT_CUTOFF:2:2} ($(minutes_left) min from now)"
. "$SCRIPT_DIR/google_guard.sh"
google_cooling && log "Google is still blocking searches from an earlier CAPTCHA (until $GOOGLE_RETRY_AT) — the scripts skip Google until then"

# The pool prep before the runs (the burn repeats it every BURN_FIX_EVERY rounds)
prep_pool() {
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
[ "$MODE" = "burn" ] && start_repair
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
}
prep_pool

# ---------------------------------------------------------------- the burn (--burn)
burn_over() {   # burn_over KIND DETAIL — a credit ran out: the burn ends for good
    log "Out of $1 credits — the burn is over"
    echo "$(date '+%Y-%m-%d %H:%M') $1 out of credits" > "$BURN_DONE"
    status alert "$1" stop "Outreach finished: $1 ran out" "$2 The 24/7 runs have stopped for good and night runs stay off (.night_off). Every contact found is in the app."
    git_sync "Burn finished: $1 out of credits" night_status.json
}

burn_loop() {
    local rounds=0 tries=0 rc retry_wait run_stats
    while :; do
        if [ -f "$BURN_PAUSE" ]; then
            log "Paused (.burn_pause) — waiting for it to be removed"
            status note "Outreach paused by Alex (.burn_pause); it picks up where it stopped."
            status_push "burn paused"
            while [ -f "$BURN_PAUSE" ]; do sleep 60; done
            log "Pause lifted — going on"
            status note "Outreach running again"
        fi
        if [ -n "$(state_get audit_pending)" ] || ! claude_ok; then
            claude_ok || claude_wait
            local p
            for p in $(state_get audit_pending); do start_dive "$p"; wait_dive; done
        fi
        apply_websites
        apply_repair
        do_run
        rc=$?
        [ "$LAST_STARTED" = 1 ] && rounds=$((rounds + 1))
        if [ "$rc" = 4 ]; then
            log "No eligible venues left — the pool needs a sweep"
            status alert pool warn "Out of venues to run" "Every venue that passes the filters has been worked. A sweep of a new city refills the pool."
            git_sync "Burn: pool empty" night_status.json
            return 0
        fi
        run_stats=$(/usr/bin/python3 "$SCRIPT_DIR/night_zero.py" "$LAST_RID" --stats 2>/dev/null | tr ' ' ',')
        # shellcheck disable=SC2046
        git_sync "Burn run $LAST_RID: ${run_stats:-${LAST_STOP:0:120}}" night_status.json $(run_files "$LAST_RID")
        [ -f "$RUNS_DIR/$LAST_RID.jsonl" ] && start_dive "$LAST_RID"
        if [ "$rc" = 0 ]; then
            tries=0
            log "Round $rounds done ($LAST_RID)"
            if [ $((rounds % BURN_FIX_EVERY)) -eq 0 ]; then
                wait_dive
                fix_session
                apply_websites wait
                apply_repair wait
                prep_pool
            fi
            continue
        fi
        classify_stop "$LAST_STOP"
        case "$STOP_KIND" in
            pause|deadline) continue ;;   # the top of the loop waits out the pause
            zerobounce)
                zb_check >/dev/null
                if [ "$ZB_REASON" = "reserve_reached" ]; then
                    burn_over zerobounce "$ZB_DETAIL"
                    return 1
                fi ;;
            apollo)
                apollo_check >/dev/null
                if [ -n "$APOLLO_LEFT" ] && [ "$APOLLO_LEFT" -lt "$APOLLO_MIN_CREDITS" ]; then
                    burn_over apollo "Apollo has $APOLLO_LEFT credits left (the floor is $APOLLO_MIN_CREDITS)."
                    return 1
                fi ;;
        esac
        # Not a credit running out (Chrome, Google, the network, ZeroBounce refusing the IP):
        # wait and pick the run up again, BURN_RETRIES times in a row before giving up
        retry_wait="$CHROME_RETRY_WAIT_S"
        google_block "$LAST_STOP" && retry_wait="$GOOGLE_RETRY_WAIT_S"
        case "$STOP_KIND" in zerobounce|apollo) retry_wait=1800 ;; esac
        if [ "$tries" -lt "$BURN_RETRIES" ]; then
            tries=$((tries + 1))
            log "Stopped ($LAST_STOP) — trying again in $((retry_wait / 60)) min ($tries of $BURN_RETRIES)"
            sleep "$retry_wait"
            continue
        fi
        log "Run stopped $tries times in a row: $LAST_STOP"
        alert_for_stop "$LAST_RID" "$LAST_STOP"
        return 1
    done
}

new_runs=0
night_state="done"
if [ "$MODE" = "burn" ]; then
    log "Burn: rounds of $RUN_SIZE until ZeroBounce or Apollo runs out (pause: touch .burn_pause)"
    status note "Outreach running 24/7 until the credits run out"
    status_push "burn started"
    burn_loop || night_state="stopped"
    NIGHT_MAX_RUNS=0   # skips the night loop below
fi
while [ "$new_runs" -lt "$NIGHT_MAX_RUNS" ]; do   # a run that couldn't start doesn't count; a resumed one does (Oct 11 2026)
    left=$(minutes_left)
    if [ "$left" -lt "$MIN_RUN_WINDOW_MIN" ]; then
        log "Only $left min before the cutoff — no more runs tonight"
        break
    fi
    apply_websites   # the research's websites, if it's done (never during a run)
    do_run
    rc=$?
    # Alex, Oct 11 2026: "1 run of 50" a night, so finishing a leftover run is the night's run too
    [ "$LAST_STARTED" = 1 ] && new_runs=$((new_runs + 1))
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
[ "$MODE" = "burn" ] && exit 0
family_tree_shift
exit 0
