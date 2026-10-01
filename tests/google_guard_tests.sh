#!/bin/bash
# Tests for google_guard.sh (the shared cooldown after Google's CAPTCHA) and the run's
# stop rule, which must not count a social step that only Google blocked (Oct 1 2026).
#   bash tests/google_guard_tests.sh
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d "${TMPDIR:-/tmp}/google_guard_tests.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
export GOOGLE_BLOCK_FILE="$T/block" GOOGLE_LAST_FILE="$T/last"
. ./google_guard.sh
fail=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }
mins_left() { local u s; read -r u s < "$GOOGLE_BLOCK_FILE"; echo $(( (u - $(date +%s) + 30) / 60 )); }

google_cooling && bad "cooling without a block" || ok "no block, no cooldown"
google_mark_blocked
[ "$GOOGLE_STRIKES" = 1 ] && [ "$(mins_left)" = 45 ] && ok "first CAPTCHA: 45 min" || bad "first block: strikes=$GOOGLE_STRIKES mins=$(mins_left)"
google_cooling && ok "cooling during the block" || bad "not cooling during the block"
google_mark_blocked
[ "$(mins_left)" = 90 ] && ok "still blocked: 90 min" || bad "second block: $(mins_left) min"
google_mark_blocked; google_mark_blocked
[ "$(mins_left)" = 180 ] && ok "capped at 180 min" || bad "cap: $(mins_left) min"
echo "$(( $(date +%s) - 60 )) 2" > "$GOOGLE_BLOCK_FILE"
google_cooling && bad "an ended block still cools" || ok "an ended block doesn't cool"
google_mark_blocked
[ "$GOOGLE_STRIKES" = 3 ] && ok "a block right after one escalates" || bad "strikes=$GOOGLE_STRIKES"
echo "$(( $(date +%s) - 30000 )) 4" > "$GOOGLE_BLOCK_FILE"
google_mark_blocked
[ "$GOOGLE_STRIKES" = 1 ] && ok "an earlier night's block doesn't escalate" || bad "strikes=$GOOGLE_STRIKES"
google_mark_ok
google_cooling && bad "a working search didn't end the block" || ok "a working search ends the block"
echo garbage > "$GOOGLE_BLOCK_FILE"
google_cooling && bad "garbage file cools" || ok "garbage file ignored"
date +%s > "$GOOGLE_LAST_FILE"; t0=$(date +%s); google_pace 2 2; dt=$(( $(date +%s) - t0 ))
[ "$dt" -ge 1 ] && [ "$dt" -le 3 ] && ok "pace waits after a search (${dt}s)" || bad "pace waited ${dt}s"
echo $(( $(date +%s) - 100 )) > "$GOOGLE_LAST_FILE"; t0=$(date +%s); google_pace 2 2
[ $(( $(date +%s) - t0 )) -le 1 ] && ok "pace doesn't wait when idle" || bad "pace waited when idle"

# The stop rule (pipeline.sh's own functions)
for fn in runner_step_status runner_social_status runner_streak; do
    awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' pipeline.sh
done > "$T/fns.sh"
. "$T/fns.sh"
chk() {
    local got; got=$(runner_social_status "$2")
    [ "$got" = "$3" ] && ok "stop rule: $1" || bad "stop rule: $1 (got '$got', want '$3')"
}
chk "IG snippet blocked by Google only" "[STEP] V social blocked fb=found problems=ig_snippet:blocked:google_captcha" ""
chk "searches blocked by Google only" "[STEP] V social blocked problems=instagram:blocked:google_captcha,facebook:blocked:google_captcha" ""
chk "Facebook login wall still counts" "[STEP] V social blocked problems=fb_page:blocked:login_wall" "blocked"
chk "wall plus Google still counts" "[STEP] V social blocked problems=fb_page:blocked:login_wall,ig_snippet:blocked:google_captcha" "blocked"
chk "Chrome failure still counts" "[STEP] V social failed problems=ig_page:failed:chrome" "failed"
chk "ok" "[STEP] V social ok fb=found ig=found" "ok"
s=0
for v in A B C; do
    s=$(runner_streak "$(runner_social_status "[STEP] $v social blocked problems=ig_snippet:blocked:google_captcha")" "$s")
done
[ "$s" = 0 ] && ok "Oct 1 replay: three Google-blocked venues don't stop the run" || bad "streak $s"
exit $fail
