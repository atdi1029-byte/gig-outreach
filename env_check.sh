# Sourced by every outreach script:   . "$SCRIPT_DIR/env_check.sh" || exit 1
#
# Makes `python3` resolve to an interpreter that actually runs on this Mac and
# can import requests. The python.org 3.9 build that ~/.bash_profile puts first
# on PATH is Intel-only and dies with "Bad CPU type" without Rosetta — and every
# `python3 ... 2>/dev/null || true` in the scripts would then quietly return
# nothing. Returns non-zero (caller exits) if no working python3 exists.

_outreach_py_ok() { "$1" -c 'import requests' >/dev/null 2>&1; }

if ! _outreach_py_ok python3; then
    for _outreach_cand in /usr/bin/python3 /opt/homebrew/bin/python3; do
        if [ -x "$_outreach_cand" ] && _outreach_py_ok "$_outreach_cand"; then
            _outreach_shim="${TMPDIR:-/tmp}/outreach-pybin-${UID:-0}"
            mkdir -p "$_outreach_shim" && ln -sf "$_outreach_cand" "$_outreach_shim/python3"
            PATH="$_outreach_shim:$PATH"
            # Apple's python links LibreSSL; urllib3 warns about it on every import.
            PYTHONWARNINGS="ignore:urllib3 v2 only supports OpenSSL${PYTHONWARNINGS:+,$PYTHONWARNINGS}"
            export PATH PYTHONWARNINGS
            break
        fi
    done
fi

if ! _outreach_py_ok python3; then
    echo "FATAL: no working python3 with 'requests' (tried PATH, /usr/bin/python3, /opt/homebrew/bin/python3)." >&2
    echo "       Fix: softwareupdate --install-rosetta, or put /usr/bin ahead of the python.org 3.9 entry in ~/.bash_profile." >&2
    return 1 2>/dev/null || exit 1
fi
