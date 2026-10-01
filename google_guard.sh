#!/bin/bash
# google_guard.sh — sourced by the scripts that search Google in Chrome (pipeline.sh,
# backfill_websites.sh). Not a command.
#
# A burst of automated searches from the home network gets Google's "unusual traffic"
# CAPTCHA page (google.com/sorry/) instead of results, for a while, and every search made
# during the block keeps it going. That ended the Sep 30 and Oct 1 nights: the website
# backfill made ~20 searches in 5 minutes at 01:00, Google blocked at the 20th, and the
# pipeline stopped two venues later with 6.5 hours of the night left.
#
# So the scripts share one block: after a CAPTCHA nobody searches Google until the cooldown
# ends (longer each time Google is still blocking after one), the searches in between are
# logged as blocked, and the run goes on without them. Nothing ever clicks the CAPTCHA.
#
#   google_cooling        0 while Google is cooling down; GOOGLE_RETRY_AT = HH:MM it ends
#   google_mark_blocked   Google just showed its CAPTCHA: start (or lengthen) the cooldown;
#                         sets GOOGLE_RETRY_AT and GOOGLE_STRIKES
#   google_mark_ok        a search worked: the block is over
#   google_pace MIN MAX   wait until a random MIN..MAX seconds have passed since the last
#                         Google search of any script (for bulk lookups)

GOOGLE_BLOCK_FILE="${GOOGLE_BLOCK_FILE:-/tmp/outreach_google_block}"   # "UNTIL_EPOCH STRIKES"
GOOGLE_LAST_FILE="${GOOGLE_LAST_FILE:-/tmp/outreach_google_last}"     # epoch of the last search
GOOGLE_COOLDOWN_MIN="${GOOGLE_COOLDOWN_MIN:-45}"
GOOGLE_COOLDOWN_MAX_MIN="${GOOGLE_COOLDOWN_MAX_MIN:-180}"
GOOGLE_RETRY_AT=""
GOOGLE_STRIKES=0

google_cooling() {
    local until strikes
    read -r until strikes 2>/dev/null < "$GOOGLE_BLOCK_FILE" || return 1
    case "$until" in ''|*[!0-9]*) return 1 ;; esac
    [ "$(date +%s)" -lt "$until" ] || return 1
    GOOGLE_RETRY_AT=$(date -r "$until" +%H:%M)
    return 0
}

google_mark_blocked() {
    local until strikes now mins i=1
    now=$(date +%s)
    read -r until strikes 2>/dev/null < "$GOOGLE_BLOCK_FILE"
    case "$until" in ''|*[!0-9]*) until=0 ;; esac
    case "$strikes" in ''|*[!0-9]*) strikes=0 ;; esac
    # A block that ended hours ago (an earlier night) doesn't make this one longer
    [ $((now - until)) -gt 21600 ] && strikes=0
    strikes=$((strikes + 1))
    mins="$GOOGLE_COOLDOWN_MIN"
    while [ "$i" -lt "$strikes" ] && [ "$mins" -lt "$GOOGLE_COOLDOWN_MAX_MIN" ]; do
        mins=$((mins * 2)); i=$((i + 1))
    done
    [ "$mins" -gt "$GOOGLE_COOLDOWN_MAX_MIN" ] && mins="$GOOGLE_COOLDOWN_MAX_MIN"
    until=$((now + mins * 60))
    echo "$until $strikes" > "$GOOGLE_BLOCK_FILE"
    GOOGLE_RETRY_AT=$(date -r "$until" +%H:%M)
    GOOGLE_STRIKES="$strikes"
}

google_mark_ok() {
    rm -f "$GOOGLE_BLOCK_FILE"
    date +%s > "$GOOGLE_LAST_FILE"
}

google_pace() {
    local min="$1" max="$2" last gap wait
    gap=$((min + RANDOM % (max - min + 1)))
    read -r last 2>/dev/null < "$GOOGLE_LAST_FILE"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    wait=$((last + gap - $(date +%s)))
    [ "$wait" -gt 0 ] && [ "$wait" -le "$max" ] && sleep "$wait"
    date +%s > "$GOOGLE_LAST_FILE"
}
