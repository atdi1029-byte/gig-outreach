#!/bin/bash
# chrome_guard.sh — sourced by the scripts that drive Chrome (pipeline.sh, postcheck.sh,
# backfill_websites.sh, discover.sh, preflight.sh). Not a command.
#
# The outreach runs need Chrome to themselves (Alex, Sep 30 2026: "we need to run alone").
# macOS hands AppleScript sent to "Google Chrome" to the NEWEST running copy of the app. A
# second copy — a headless or puppeteer test started from /Applications/Google Chrome.app —
# silently takes every command: navigations land in it, and JavaScript fails with "turned
# off" because its throwaway profile has JavaScript from Apple Events off. That is what
# stopped the Sep 30 night at 01:09 (another Claude session's Books app tests). Tests now
# use Chrome for Testing, a separate app that can't take the commands; this is the net.
#
#   chrome_copies              one line per running Google Chrome (helpers and Chrome for
#                              Testing don't count), oldest first:
#                              PID <tab> AUTO <tab> AGE_SECONDS <tab> STARTED_BY
#                              AUTO=1: a program started it (headless, automation or remote
#                              debugging flags); STARTED_BY: its parent command, shortened
#   chrome_wait_alone [MAX_S]  0 = Alex's Chrome is the only copy. With more copies it waits
#                              up to MAX_S (default CHROME_ALONE_WAIT_S, 600) for the others
#                              to quit; with CHROME_ALONE_KILL=1 (night runs) it then closes
#                              the program-started ones. 1 = still not alone, 2 = Chrome is
#                              not running. CHROME_ALONE_DETAIL says why, in plain words.

CHROME_ALONE_DETAIL=""

# To stderr (so it never lands in a caller's $(...)), and to the caller's LOG_FILE if any
_cg_say() {
    printf '%s\n' "$*" >&2
    [ -n "${LOG_FILE:-}" ] && printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
    return 0
}

_cg_seconds() {   # ps etime ([[dd-]hh:]mm:ss) -> seconds
    local e="$1" d=0 a b c
    case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
    IFS=: read -r a b c <<< "$e"
    if [ -n "$c" ]; then
        echo $(( 10#$d * 86400 + 10#$a * 3600 + 10#$b * 60 + 10#$c ))
    else
        echo $(( 10#$d * 86400 + 10#${a:-0} * 60 + 10#${b:-0} ))
    fi
}

_cg_short() {   # "/usr/local/bin/node /x/y/test.js --a" -> "node test.js --a" (3 words, 60 chars)
    local words=() out="" i
    read -ra words <<< "$1"
    for ((i = 0; i < ${#words[@]} && i < 3; i++)); do
        out="${out:+$out }${words[$i]##*/}"
    done
    printf '%s' "${out:0:60}"
}

chrome_copies() {
    local pid ppid etime args auto line
    for pid in $(pgrep -x -U "$(id -u)" "Google Chrome" 2>/dev/null); do
        line=$(ps -o ppid=,etime= -p "$pid" 2>/dev/null) || continue
        read -r ppid etime <<< "$line"
        [ -n "$etime" ] || continue
        args=$(ps -ww -o command= -p "$pid" 2>/dev/null)
        auto=0
        case " $args " in
            *" --headless"*|*" --enable-automation"*|*" --remote-debugging-pipe"*|*" --remote-debugging-port"*) auto=1 ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$pid" "$auto" "$(_cg_seconds "$etime")" \
            "$(_cg_short "$(ps -ww -o command= -p "$ppid" 2>/dev/null)")"
    done | sort -t $'\t' -k3,3nr
}

# Every copy but Alex's (the oldest one nobody's program started)
_cg_extras() { printf '%s\n' "$1" | awk -F'\t' 'NF && !mine && $2 == 0 { mine = 1; next } NF { print }'; }

_cg_describe() {   # "PID 38371, a headless/test copy started by node live_offline.js; ..."
    printf '%s\n' "$1" | awk -F'\t' 'NF {
        n++
        if (n > 2) next
        d = "PID " $1
        if ($2 == 1) d = d ", a headless/test copy"
        if ($4 != "") d = d " started by " $4
        out = (out == "" ? d : out "; " d)
    } END { if (n > 2) out = out " and " (n - 2) " more"; print out }'
}

chrome_wait_alone() {
    local max="${1:-${CHROME_ALONE_WAIT_S:-600}}" waited=0 copies extra pids told=0 i
    CHROME_ALONE_DETAIL=""
    while :; do
        copies=$(chrome_copies)
        if ! printf '%s\n' "$copies" | awk -F'\t' '$2 == 0 { found = 1 } END { exit !found }'; then
            CHROME_ALONE_DETAIL="Google Chrome is not running"
            [ -n "$copies" ] && CHROME_ALONE_DETAIL="$CHROME_ALONE_DETAIL (only a copy a program started: $(_cg_describe "$copies"))"
            return 2
        fi
        extra=$(_cg_extras "$copies")
        if [ -z "$extra" ]; then
            [ "$told" = 1 ] && _cg_say "[CHROME] The other copy of Chrome is gone after ${waited}s — going on"
            return 0
        fi
        if [ "$told" = 0 ]; then
            _cg_say "[CHROME] Another copy of Google Chrome is running ($(_cg_describe "$extra")). Chrome commands would go to it, so waiting up to $(( (max + 59) / 60 )) min for it to close"
            told=1
        fi
        [ "$waited" -ge "$max" ] && break
        sleep 10
        waited=$((waited + 10))
    done
    if [ "${CHROME_ALONE_KILL:-0}" = 1 ]; then
        pids=$(printf '%s\n' "$extra" | awk -F'\t' '$2 == 1 { print $1 }')
        if [ -n "$pids" ]; then
            _cg_say "[CHROME] Still there after ${waited}s — closing the program-started copy (PID $(echo $pids)) so the run has Chrome to itself"
            kill -TERM $pids 2>/dev/null
            for i in 1 2 3 4 5 6 7 8 9 10; do
                sleep 1
                kill -0 $pids 2>/dev/null || break
            done
            kill -KILL $pids 2>/dev/null
            sleep 1
            extra=$(_cg_extras "$(chrome_copies)")
            if [ -z "$extra" ]; then
                _cg_say "[CHROME] Closed — going on"
                return 0
            fi
        fi
    fi
    CHROME_ALONE_DETAIL="another copy of Google Chrome is running ($(_cg_describe "$extra")), so Chrome commands would go to it instead of your Chrome"
    return 1
}
