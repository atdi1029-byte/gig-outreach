#!/usr/bin/env bash
# Offline tests for site_discovery.py. Serves local fixtures; no network, no side effects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/env_check.sh" || exit 1
TMP_SITE="$(mktemp -d)"
# Other test suites run fixture servers too, so each port is taken free from the OS
# (a fixed port once pointed this suite at someone else's fixture site).
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT="${OUTREACH_TEST_PORT:-$(free_port)}"
PORT2=$(free_port)
PORT3=$(free_port)
PORT4=$(free_port)
PORT5=$(free_port)
PID=""
PID2=""
PIDS_MORE=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  [ -n "$PID2" ] && kill "$PID2" 2>/dev/null || true
  for p in $PIDS_MORE; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP_SITE"
}
trap cleanup EXIT
# Tests don't need to be polite to themselves.
export SITE_DISCOVERY_DELAY="${SITE_DISCOVERY_DELAY:-0}"

mkdir -p "$TMP_SITE/events" "$TMP_SITE/deep" "$TMP_SITE/hidden" "$TMP_SITE/private"
cat > "$TMP_SITE/index.html" <<'HTML'
<html><body>
<a href="/events#events-cta">Events CTA</a>
<a href="/about.html">About</a>
<a href="/private/secret.html">Members</a>
<a href="/contact.html">Contact</a>
</body></html>
HTML
cat > "$TMP_SITE/events/index.html" <<'HTML'
<html><body>
<a href="/deep/team.html">Meet the Events Team</a>
<a href="/private-events.pdf">Private Events PDF</a>
<span>rebecca [at] venue [dot] com</span>
<p>Join us at Clyde dot com for dinner.</p>
</body></html>
HTML
# Inline JSON with JS escapes (backslash-u003e before the address) must not yield "u003ejsinfo@".
python3 - "$TMP_SITE/about.html" <<'PY2'
import sys
bs = chr(92)
esc = lambda s: "".join(bs + "u%04x" % ord(c) for c in s)
open(sys.argv[1], "w").write(
    '<html><body><a href="https://www.instagram.com/venue.social/">Instagram</a>'
    '<script>var cfg={"footer":"' + esc("<p>") + esc(">") + 'jsinfo@venue.com' + esc("</p>") + '"};</script>'
    '</body></html>')
PY2
cat > "$TMP_SITE/deep/team.html" <<'HTML'
<html><body><a href="https://www.facebook.com/venuepage/">Facebook</a>
<h3>Dana Whitfield</h3><p>Director of Events</p><p>director@venue.com</p>
<p>Bookings: sales<span>@</span>venue<span>.</span>com</p>
<form action="/deep/send" method="post"><input name="name"><input type="email" name="email"><textarea name="message"></textarea></form>
</body></html>
HTML
cat > "$TMP_SITE/hidden/private-events.html" <<'HTML'
<html><body>events@venue.com</body></html>
HTML
cat > "$TMP_SITE/private/secret.html" <<'HTML'
<html><body>secret@venue.com</body></html>
HTML
cat > "$TMP_SITE/robots.txt" <<'TXT'
User-agent: *
Disallow: /private/
TXT
# WordPress antispambot (entity-encoded mailto) + Cloudflare href-only protection
# + percent-encoded mailto.
/usr/bin/env python3 - "$TMP_SITE/contact.html" <<'PY'
import sys
def ents(s): return "".join("&#%d;" % ord(c) for c in s)
key = 0x42
cf = "%02x" % key + "".join("%02x" % (ord(c) ^ key) for c in "cfevents@venue.com")
open(sys.argv[1], "w").write(
    '<html><body>'
    '<a href="' + ents("mailto:") + ents("wpevents@venue.com") + '">' + ents("wpevents@venue.com") + '</a>'
    '<a href="/cdn-cgi/l/email-protection#' + cf + '">[email&#160;protected]</a>'
    '<a href="mailto:%20pct.person@venue.com">Email</a>'
    '<a href="mailto:catering%40venue.com">Catering</a>'
    '</body></html>')
PY
cat > "$TMP_SITE/sitemap.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>http://127.0.0.1:${PORT}/hidden/private-events.html</loc></url>
</urlset>
XML

# A tiny PDF-like fixture. If pypdf/pdftotext are unavailable, site_discovery.py's
# last-resort byte scan must still retain a literal email candidate.
printf '%%PDF-1.4\nPrivate Events Catering contact: catering@venue.com\n%%%%EOF\n' > "$TMP_SITE/private-events.pdf"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$TMP_SITE" >/dev/null 2>&1 &
PID=$!
disown "$PID" 2>/dev/null || true

# Second server: 127.0.0.1 redirects to localhost (a venue whose stored domain moved).
# /celebrations is linked only from the new host's homepage.
mkdir -p "$TMP_SITE/moved"
cat > "$TMP_SITE/moved/index.html" <<'HTML'
<html><body><a href="/celebrations.html">Celebrations</a></body></html>
HTML
cat > "$TMP_SITE/moved/celebrations.html" <<'HTML'
<html><body>events-manager@venue.com</body></html>
HTML
python3 - "$PORT2" "$TMP_SITE/moved" >/dev/null 2>&1 <<'PY' &
import http.server, os, sys
port, root = int(sys.argv[1]), sys.argv[2]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def do_GET(self):
        if self.headers.get("Host", "").startswith("127.0.0.1"):
            self.send_response(301)
            self.send_header("Location", "http://localhost:%d%s" % (port, self.path))
            self.end_headers()
            return
        return super().do_GET()
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("", port), H).serve_forever()
PY
PID2=$!
disown "$PID2" 2>/dev/null || true
# Extra single-purpose sites: an old frameset site with a meta-refresh page, a site
# that refuses scripted visitors (403), and a robots.txt with a blanket Disallow: /.
mkdir -p "$TMP_SITE/legacy" "$TMP_SITE/blanket"
cat > "$TMP_SITE/legacy/index.html" <<'HTML'
<html><frameset cols="20%,80%"><frame src="nav.html"><frame src="main.html"></frameset></html>
HTML
cat > "$TMP_SITE/legacy/nav.html" <<'HTML'
<html><head><meta http-equiv="refresh" content="0; url=/weddings.html"></head><body></body></html>
HTML
cat > "$TMP_SITE/legacy/main.html" <<'HTML'
<html><body>Write to us: owner AT legacyinn DOT com</body></html>
HTML
cat > "$TMP_SITE/legacy/weddings.html" <<'HTML'
<html><body><iframe src="https://api.tripleseat.com/v1/leads/ws/lead_form?lead_form_id=9"></iframe>weddings@legacyinn.com</body></html>
HTML
cat > "$TMP_SITE/blanket/index.html" <<'HTML'
<html><body><a href="/contact.html">Contact</a></body></html>
HTML
cat > "$TMP_SITE/blanket/contact.html" <<'HTML'
<html><body><a href="mailto:hello@blanketvenue.com">Email</a></body></html>
HTML
printf 'User-agent: *\nDisallow: /\n' > "$TMP_SITE/blanket/robots.txt"
for spec in "$PORT3:legacy" "$PORT4:blocked" "$PORT5:blanket"; do
python3 - "${spec%%:*}" "$TMP_SITE/${spec##*:}" "${spec##*:}" >/dev/null 2>&1 <<'PY' &
import http.server, os, sys
port, root, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3]
os.makedirs(root, exist_ok=True)
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def do_GET(self):
        if mode == "blocked":
            self.send_response(403); self.end_headers(); self.wfile.write(b"Forbidden"); return
        return super().do_GET()
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
PIDS_MORE="$PIDS_MORE $!"
disown "$!" 2>/dev/null || true
done
sleep 1

OUT="$(mktemp)"
ERR="$(mktemp)"
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT}/" --max-pages 20 --max-depth 3 > "$OUT"
python3 - "$OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
emails={x['email'] for x in d['contacts']}
expected={'rebecca@venue.com','director@venue.com','events@venue.com','catering@venue.com',
          'jsinfo@venue.com','wpevents@venue.com','cfevents@venue.com','pct.person@venue.com'}
assert expected <= emails, f"missing emails: {expected-emails}; got {emails}"
bad = {e for e in emails if e.startswith(('u003', '%20', 'us@')) or 'clyde' in e}
assert not bad, f"invented addresses: {bad}"
assert 'secret@venue.com' not in emails, "robots.txt Disallow: /private/ was ignored"
assert d['coverage']['robots_disallowed_count'] >= 1, d['coverage']
mailto={x['email'] for x in d['contacts'] if x.get('mailto')}
assert {'wpevents@venue.com','cfevents@venue.com','pct.person@venue.com','catering@venue.com'} <= mailto, mailto
socials={(x['platform'],x['url']) for x in d['socials']}
assert ('instagram','https://www.instagram.com/venue.social/') in socials, socials
assert ('facebook','https://www.facebook.com/venuepage/') in socials, socials
assert any('#events-cta' in x for x in d['fragment_states']), d['fragment_states']
assert d['coverage']['sitemap_count'] >= 1, d['coverage']
assert d['coverage']['pdf_count'] >= 1, d['coverage']
assert d['coverage']['successful_page_count'] >= 5, d['coverage']
assert 'sales@venue.com' in emails, f"tag-split address missed: {emails}"
director = [x for x in d['contacts'] if x['email'] == 'director@venue.com'][0]
assert director['name_hint'] == 'Dana Whitfield' and 'Director' in director['title_hint'], director
assert director['contexts'] and 'Dana Whitfield' in director['contexts'][0]['text'], director
assert any(f['kind'] == 'html_form' and f['url'].endswith('/deep/team.html') for f in d['contact_forms']), d['contact_forms']
kinds = set(d['coverage']['page_kinds_visited'])
assert {'home', 'contact', 'about', 'events', 'team'} <= kinds, d['page_kinds']
assert d['coverage']['blocked'] is False and d['coverage']['home_status'] == '200', d['coverage']
print('PASS: recursive crawl, hash states, sitemap, PDF, obfuscated/encoded/tag-split emails, robots.txt, Facebook, Instagram, name hints, contact form, page kinds')
PY

# DS-2 / CC-8: a budget smaller than the number of high-value pages leaves pages
# unvisited. Their diagnostics must go to stderr; stdout must still be pure JSON.
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT}/" --max-pages 1 --max-depth 3 > "$OUT" 2> "$ERR"
python3 - "$OUT" "$ERR" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d['coverage']['high_priority_unvisited_count'] > 0, d['coverage']
assert 'HIGH_PRIORITY_UNVISITED' in open(sys.argv[2]).read(), 'diagnostic missing from stderr'
print('PASS: small page budget still prints valid JSON on stdout (diagnostics on stderr)')
PY

# DS-18: follow the stored website's redirect to its new host.
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT2}/" --max-pages 10 --max-depth 2 > "$OUT"
python3 - "$OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
emails={x['email'] for x in d['contacts']}
assert 'events-manager@venue.com' in emails, f"redirect target not crawled: {emails} {d['pages']}"
assert d['redirected_to'].startswith('http://localhost:'), d['redirected_to']
print('PASS: crawl follows a cross-host redirect')
PY

# --path-prefix (a property's section of a shared brand domain) keeps the crawl inside it.
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT}/" --max-pages 20 --max-depth 3 --path-prefix /deep > "$OUT" 2>/dev/null
python3 - "$OUT" <<'PY'
import json, sys
from urllib.parse import urlparse
d=json.load(open(sys.argv[1]))
paths = {urlparse(p['url']).path for p in d['pages']}
assert paths <= {'/', '/deep/team.html'}, paths
assert d['coverage']['path_prefix'] == '/deep', d['coverage']
print('PASS: --path-prefix limits the crawl to the property section')
PY

# Frameset + meta refresh + uppercase AT/DOT + embedded Tripleseat lead form.
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT3}/" --max-pages 10 --max-depth 3 > "$OUT"
python3 - "$OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
emails={x['email'] for x in d['contacts']}
assert {'owner@legacyinn.com', 'weddings@legacyinn.com'} <= emails, f"frameset/meta-refresh pages missed: {emails} {d['pages']}"
assert any(f['kind'] == 'tripleseat' for f in d['contact_forms']), d['contact_forms']
print('PASS: frames, meta refresh, AT/DOT obfuscation, embedded lead form')
PY

# A site that refuses scripted visitors must say so (blocked), not look empty, and stop early.
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT4}/" --max-pages 40 --max-depth 3 > "$OUT" 2>/dev/null
python3 - "$OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
c=d['coverage']
assert c['blocked'] is True and c['blocked_reason'] == 'http_403', c
assert c['attempt_count'] <= 4, c
print('PASS: a 403 site is reported as blocked and the crawl stops early')
PY

# robots.txt "Disallow: /" for everyone is recorded, not applied to the venue's public pages.
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT5}/" --max-pages 5 --max-depth 2 > "$OUT"
python3 - "$OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
c=d['coverage']
assert c['robots_blanket_disallow'] is True and c['robots_honored'] is False, c
assert 'hello@blanketvenue.com' in {x['email'] for x in d['contacts']}, d['contacts']
print('PASS: blanket robots Disallow is flagged and the public pages are still read')
PY

# Page-level extractors (no server): Cloudflare-protected staff directory, [at]
# obfuscation with name + title, people without emails, PDFs, raw-byte PDF noise.
python3 - "$SCRIPT_DIR" <<'PY'
import sys, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, sys.argv[1])
import site_discovery as S
key = 0x42
enc = "%02x" % key + "".join("%02x" % (ord(c) ^ key) for c in "afrantz@clubcc.org")
html = ('<p>Devika Strother, Founder devika[at]gallery.org</p>'
        '<div><h4>Andrew Frantz</h4><p>General Manager</p><a href="/cdn-cgi/l/email-protection#' + enc + '">'
        '<span class="__cf_email__" data-cfemail="' + enc + '">[email&#160;protected]</span></a></div>'
        '<p>Eric Kole, General Manager &amp; Partner</p><p>The owners Bert and Lynne Smith: bert@x.com</p>')
text = S.page_text(html)
emails = [e["email"] for e in S.extract_emails(html)]
assert {"devika@gallery.org", "afrantz@clubcc.org", "bert@x.com"} <= set(emails), emails
ctx = S.email_contexts(text, emails)
assert ctx["afrantz@clubcc.org"]["name_hint"] == "Andrew Frantz", ctx
assert ctx["afrantz@clubcc.org"]["title_hint"] == "General Manager", ctx
assert ctx["devika@gallery.org"]["name_hint"] == "Devika Strother", ctx
assert ctx["bert@x.com"]["name_hint"] == "", ctx  # "Lynne Smith" is not bert@
people = {p["name"]: p["title"] for p in S.extract_people(text)}
assert people.get("Eric Kole") == "General Manager & Partner", people
assert "Blue Duck Tavern" not in people, people
# Cleaning up after a sentence must not glue words onto an address.
assert [e["email"] for e in S.extract_emails("for details.</span> <span>lynne@x.com")] == ["lynne@x.com"]
# A pathological page must not hang the regexes.
import time
t0 = time.time()
S.extract_emails("@" + "abc." * 5000 + " <b> x" + ("a" + " <i> " * 3000 + ". ") * 3 + "@venue")
assert time.time() - t0 < 10, "email regexes are too slow on a pathological page"
raw = b"%PDF-1.4\nnoise 6@u.ijw k@48g9-.bybgnptut catering@venue.com\n%%EOF"
got = {e["email"] for e in S.extract_emails(S._pdf_text_from_bytes(raw))}
assert "catering@venue.com" in got, got
try:
    import fitz
except Exception:
    fitz = None
if fitz is not None:
    doc = fitz.open(); page = doc.new_page()
    page.insert_text((72, 72), "Private events: Jane Doe, Events Manager, jane.doe@venue.com")
    page.insert_link({"kind": fitz.LINK_URI, "from": fitz.Rect(72, 100, 200, 120), "uri": "mailto:events@venue.com"})
    text, method = S._pdf_text_and_method(doc.tobytes(deflate=True))
    assert method == "pymupdf", method
    assert {"jane.doe@venue.com", "events@venue.com"} <= {e["email"] for e in S.extract_emails(text)}, text
print("PASS: Cloudflare/[at] name pairing, people without email, name-vs-address check, PDFs, regex speed")
PY

python3 - "$SCRIPT_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from site_discovery import parse_location
cases = {
    '1309 5th St NE, Washington, DC 20002': ('Washington', 'DC'),
    '1309 5th St NE': ('', ''),
    '600 Water St SW, Washington, DC 20024': ('Washington', 'DC'),
    'Omaha, NE 68102': ('Omaha', 'NE'),
    '301 Maple Ave W, Vienna, VA 22180': ('Vienna', 'VA'),
    'Wilmington, DE 19801': ('Wilmington', 'DE'),
    'Great Falls, VA': ('Great Falls', 'VA'),
}
for text, want in cases.items():
    got = parse_location(text)
    assert got == want, (text, got, want)
print('PASS: location parsing (DC quadrants are not Nebraska)')
PY
rm -f "$OUT" "$ERR"
