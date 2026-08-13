#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_SITE="$(mktemp -d)"
PORT="${OUTREACH_TEST_PORT:-18765}"
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$TMP_SITE"
}
trap cleanup EXIT

mkdir -p "$TMP_SITE/events" "$TMP_SITE/deep" "$TMP_SITE/hidden"
cat > "$TMP_SITE/index.html" <<'HTML'
<html><body>
<a href="/events#events-cta">Events CTA</a>
<a href="/about.html">About</a>
</body></html>
HTML
cat > "$TMP_SITE/events/index.html" <<'HTML'
<html><body>
<a href="/deep/team.html">Meet the Events Team</a>
<a href="/private-events.pdf">Private Events PDF</a>
<span>rebecca [at] venue [dot] com</span>
</body></html>
HTML
cat > "$TMP_SITE/about.html" <<'HTML'
<html><body><a href="https://www.instagram.com/venue.social/">Instagram</a></body></html>
HTML
cat > "$TMP_SITE/deep/team.html" <<'HTML'
<html><body><a href="https://www.facebook.com/venuepage/">Facebook</a><p>director@venue.com</p></body></html>
HTML
cat > "$TMP_SITE/hidden/private-events.html" <<'HTML'
<html><body>events@venue.com</body></html>
HTML
cat > "$TMP_SITE/sitemap.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>http://127.0.0.1:${PORT}/hidden/private-events.html</loc></url>
</urlset>
XML

# A tiny PDF-like fixture. If pypdf/pdftotext are unavailable, site_discovery.py's
# last-resort byte scan must still retain a literal email candidate.
printf '%%PDF-1.4\nPrivate Events Catering contact: catering@venue.com\n%%%%EOF\n' > "$TMP_SITE/private-events.pdf"

python3 -m http.server "$PORT" --directory "$TMP_SITE" >/tmp/outreach_site_discovery_test_http.log 2>&1 &
PID=$!
sleep 1

OUT="$(mktemp)"
python3 "$SCRIPT_DIR/site_discovery.py" static-crawl "http://127.0.0.1:${PORT}/" --max-pages 20 --max-depth 3 > "$OUT"
python3 - "$OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
emails={x['email'] for x in d['contacts']}
expected={'rebecca@venue.com','director@venue.com','events@venue.com','catering@venue.com'}
assert expected <= emails, f"missing emails: {expected-emails}; got {emails}"
socials={(x['platform'],x['url']) for x in d['socials']}
assert ('instagram','https://www.instagram.com/venue.social/') in socials, socials
assert ('facebook','https://www.facebook.com/venuepage/') in socials, socials
assert any('#events-cta' in x for x in d['fragment_states']), d['fragment_states']
assert d['coverage']['sitemap_count'] >= 1, d['coverage']
assert d['coverage']['pdf_count'] >= 1, d['coverage']
assert d['coverage']['successful_page_count'] >= 5, d['coverage']
print('PASS: recursive crawl, hash states, sitemap, PDF, obfuscated email, Facebook, Instagram')
PY
rm -f "$OUT"
