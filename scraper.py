#!/usr/bin/env python3
"""
Gig Outreach Scraper — Maryland Wineries MVP
Scrapes marylandwine.com directory, extracts emails + social links,
verifies via ZeroBounce, pushes to Google Sheet via Apps Script.

Venues are added as needs_review (discovery never creates untouched venues).
Emails follow the pipeline's save policy (outreach_rules.check_email): junk,
hard-reject and off-domain addresses are never paid for or saved; role
mailboxes need a person name (this scraper has none, so they are logged);
personal mailboxes are saved when ZeroBounce says valid, or as unverified when
it couldn't check. Everything not saved goes to reports/discovery-candidates.jsonl.
"""

import os
from datetime import datetime, timezone

import requests
from bs4 import BeautifulSoup
import re
import json
import time
import urllib.parse
import sys

# === CONFIG ===
APPS_SCRIPT_URL = "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
# ZeroBounce calls MUST go through zerobounce_guard.py — no direct API access.
# The old ZEROBOUNCE_API_KEY and ZEROBOUNCE_URL have been removed.
# Use zerobounce_guard.verify_email() for all verification.
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
HEADERS = {"User-Agent": USER_AGENT}

# Email patterns to ignore (not real contact emails)
JUNK_EMAIL_PATTERNS = [
    '.png', '.jpg', '.gif', '.svg', '.css', '.js',
    'wix.com', 'wordpress', 'sentry.io', 'cloudflare',
    'example.com', 'yourdomain', 'email.com', 'test.com',
    'squarespace', 'shopify', 'mailchimp', 'constant',
    'googleapis', 'google.com', 'gstatic', 'facebook',
    'instagram', 'twitter', 'sentry', 'wixpress',
    'hubspot', 'sendgrid', 'mandrillapp', 'zendesk'
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import outreach_rules as R  # noqa: E402
CANDIDATE_LOG = os.path.join(SCRIPT_DIR, 'reports', 'discovery-candidates.jsonl')

# Max venues to scrape (set low for testing)
MAX_VENUES = 2


def fetch_page(url, timeout=15):
    """Fetch a page with browser UA. Returns BeautifulSoup or None."""
    try:
        resp = requests.get(url, headers=HEADERS, timeout=timeout)
        resp.raise_for_status()
        return BeautifulSoup(resp.text, 'html.parser')
    except Exception as e:
        print(f"  [ERROR] Failed to fetch {url}: {e}")
        return None


def scrape_winery_directory():
    """Scrape marylandwine.com/wineries/ for all winery detail page links."""
    print("Fetching Maryland wine directory...")
    soup = fetch_page("https://marylandwine.com/wineries/")
    if not soup:
        print("Failed to fetch directory page!")
        return []

    # Find winery links — they're links to /wineries/SLUG/
    links = set()
    for a in soup.find_all('a', href=True):
        href = a['href']
        # Match /wineries/something/ but not /wineries/ itself
        if re.match(r'^/wineries/[a-z0-9-]+/?$', href):
            full_url = "https://marylandwine.com" + href.rstrip('/') + '/'
            links.add(full_url)
        elif re.match(r'^https://marylandwine\.com/wineries/[a-z0-9-]+/?$', href):
            links.add(href.rstrip('/') + '/')

    print(f"Found {len(links)} winery pages")
    return sorted(links)


def scrape_winery_detail(url):
    """Scrape individual winery page on marylandwine.com."""
    soup = fetch_page(url)
    if not soup:
        return None

    venue = {
        'name': '',
        'category': 'winery',
        'website': '',
        'city': '',
        'county': '',
        'state': 'MD',
        'address': '',
        'facebook': '',
        'instagram': '',
        'source': 'marylandwine.com',
        'upscale_score': '3',
        'zone_priority': 'default',
        'status': 'needs_review',
    }

    # Name — usually in h1 or h2
    h1 = soup.find('h1')
    if h1:
        venue['name'] = h1.get_text(strip=True)
    else:
        h2 = soup.find('h2')
        if h2:
            venue['name'] = h2.get_text(strip=True)

    # Address — look for text with MD/Maryland pattern
    text = soup.get_text()
    # Try full address with zip
    addr_match = re.search(r'(\d+[^,\n]+,\s*[A-Za-z\s]+,\s*MD\s*\d{5})', text)
    if addr_match:
        venue['address'] = addr_match.group(1).strip()
        parts = venue['address'].split(',')
        if len(parts) >= 2:
            venue['city'] = parts[-2].strip()

    # Fallback: look for "City, MD" pattern
    if not venue['city']:
        city_match = re.search(r'([A-Z][a-z]+(?:\s[A-Z][a-z]+)*),\s*MD', text)
        if city_match:
            venue['city'] = city_match.group(1).strip()

    # Fallback: look for location-like text near address markers
    if not venue['city']:
        for tag in soup.find_all(['p', 'span', 'div']):
            tag_text = tag.get_text(strip=True)
            city_m = re.search(r'([A-Z][a-z]+(?:\s[A-Z][a-z]+)*),?\s*(?:MD|Maryland)', tag_text)
            if city_m:
                venue['city'] = city_m.group(1).strip()
                break

    # Website link — look for "Visit Website" or external links
    for a in soup.find_all('a', href=True):
        href = a['href']
        link_text = a.get_text(strip=True).lower()
        if 'visit website' in link_text or 'visit site' in link_text:
            venue['website'] = href
            break
        if href.startswith('http') and 'marylandwine.com' not in href and 'facebook' not in href and 'instagram' not in href:
            if not venue['website'] and '.' in href:
                venue['website'] = href

    # Social links — skip Maryland Wine Association's own social pages
    for a in soup.find_all('a', href=True):
        href = a['href'].lower()
        if 'facebook.com' in href and 'marylandwine' not in href and not venue['facebook']:
            venue['facebook'] = a['href']
        if 'instagram.com' in href and 'marylandwine' not in href and not venue['instagram']:
            venue['instagram'] = a['href']

    return venue


def scrape_website_emails(url):
    """Recursively discover email candidates on a venue website.

    Uses the same site-discovery engine as pipeline.sh so this older MVP path no
    longer has a separate homepage+/contact-only definition of "website checked".
    """
    if not url:
        return []

    if not url.startswith('http'):
        url = 'https://' + url

    try:
        from site_discovery import static_crawl
        result = static_crawl(url, max_pages=40, max_depth=3, timeout=12)
        return sorted({c.get('email', '') for c in result.get('contacts', []) if c.get('email')})
    except Exception as e:
        print(f"  [WARN] Shared recursive discovery failed for {url}: {e}; using single-page fallback")
        try:
            resp = requests.get(url, headers=HEADERS, timeout=15)
            resp.raise_for_status()
            emails = set(re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', resp.text))
            return sorted(e for e in emails if not any(j in e.lower() for j in JUNK_EMAIL_PATTERNS))
        except Exception as fallback_error:
            print(f"  [ERROR] Failed to scrape {url}: {fallback_error}")
            return []


def scrape_facebook_email(fb_url):
    """Try to scrape email from Facebook About/Contact page."""
    if not fb_url:
        return []

    about_url = fb_url.rstrip('/') + '/about'
    try:
        resp = requests.get(about_url, headers=HEADERS, timeout=10)
        emails = set(re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', resp.text))
        return [e for e in emails if not any(j in e.lower() for j in JUNK_EMAIL_PATTERNS)]
    except:
        return []


def verify_email(email):
    """Delegate to zerobounce_guard.py — the ONLY permitted ZeroBounce path.

    Returns the status string (e.g. 'valid', 'invalid', 'do_not_mail', 'unknown').
    Respects ZB_ENABLED, run/day caps, dedup cache, and all guard protections.
    """
    try:
        from zerobounce_guard import verify_email as guarded_verify
        result = guarded_verify(email, source="scraper")
        status = result.get("status", "deferred")
        print(f"  [VERIFY] {email} → {status} ({result.get('reason', '')}, via guard)")
        return status
    except Exception as e:
        # a guard crash is "couldn't check", not an "unknown" verdict
        print(f"  [ERROR] ZeroBounce guard failed for {email}: {e}")
        return 'deferred'


def record_candidate(venue_id, email, source, disposition):
    row = {'timestamp': datetime.now(timezone.utc).isoformat(), 'venue_id': venue_id, 'email': email,
           'name': '', 'title': '', 'source': source, 'disposition': disposition, 'evidence_url': ''}
    try:
        os.makedirs(os.path.dirname(CANDIDATE_LOG), exist_ok=True)
        with open(CANDIDATE_LOG, 'a', encoding='utf-8') as f:
            f.write(json.dumps(row) + '\n')
    except OSError as e:
        print(f"  [WARN] candidate log: {e}")


def save_email(venue, email, source, on_venue_site):
    """Apply the pipeline's save policy to one address. Returns the outcome word."""
    chk = R.check_email(email, venue_domain=venue.get('website', ''), venue_name=venue['name'],
                        found_on_venue_site=on_venue_site)
    email = chk['email'] or email
    if chk['action'] == 'reject':
        record_candidate(venue['venue_id'], email, source, 'reject:' + chk['reason'])
        return 'rejected (' + chk['reason'] + ')'
    if chk['action'] == 'role':
        # never sent to ZeroBounce; saved only with a real person name, which we don't have
        record_candidate(venue['venue_id'], email, source, 'role_no_person_name')
        return 'role mailbox, no name — logged'
    status = verify_email(email)
    time.sleep(1)  # Rate limit ZeroBounce
    if status == 'valid':
        verified = 'valid'
    elif status == 'deferred':
        verified = 'unverified'      # ZeroBounce couldn't check (e.g. out of credits): saved, re-check later
    else:
        record_candidate(venue['venue_id'], email, source, 'verification:' + status)
        return 'not saved (ZeroBounce ' + status + ')'
    resp = push_to_sheet('add_contact', {
        'venue_id': venue['venue_id'], 'email': email, 'source': source, 'verified': verified,
        'name': chk['name_hint'], 'title': ''})
    if resp.get('status') != 'ok':
        record_candidate(venue['venue_id'], email, source, 'api_save_failed')
        return 'save FAILED: ' + str(resp.get('message', resp))[:120]
    return 'duplicate' if resp.get('duplicate') else 'saved (' + verified + ')'


def push_to_sheet(action, params):
    """Push data to Google Sheet via Apps Script GET."""
    if not APPS_SCRIPT_URL:
        print(f"  [SKIP] No Apps Script URL — would push: {action} → {params.get('name', params.get('email', ''))}")
        return {'status': 'skipped'}

    params['action'] = action
    try:
        resp = requests.get(APPS_SCRIPT_URL, params=params, allow_redirects=True, timeout=30)
        return resp.json()
    except Exception as e:
        print(f"  [ERROR] Push failed: {e}")
        return {'status': 'error', 'message': str(e)}


def get_zone_priority(city):
    """Determine zone priority based on city name."""
    city_lower = (city or '').lower()

    green_zones = [
        'washington', 'bethesda', 'chevy chase', 'potomac', 'rockville',
        'annapolis', 'easton', 'st. michaels', 'oxford', 'ellicott city',
        'columbia', 'towson', 'timonium', 'hunt valley', 'mclean',
        'arlington', 'alexandria', 'great falls', 'middleburg'
    ]
    yellow_zones = [
        'baltimore', 'frederick', 'bowie', 'laurel', 'silver spring',
        'gaithersburg', 'germantown', 'hagerstown', 'salisbury',
        'college park', 'glen burnie', 'pasadena'
    ]

    for zone in green_zones:
        if zone in city_lower:
            return 'green'
    for zone in yellow_zones:
        if zone in city_lower:
            return 'yellow'
    return 'default'


def main():
    """Full pipeline: scrape → verify → push."""
    print("=" * 50)
    print("GIG OUTREACH SCRAPER — Maryland Wineries")
    print("=" * 50)
    print(f"Max venues: {MAX_VENUES}")
    print(f"Apps Script URL: {'SET' if APPS_SCRIPT_URL else 'NOT SET (dry run)'}")
    print(f"ZeroBounce: routed through zerobounce_guard.py")
    print()

    # Step 1: Get all winery URLs
    winery_urls = scrape_winery_directory()
    if not winery_urls:
        print("No wineries found. Exiting.")
        return

    # Limit for testing
    winery_urls = winery_urls[:MAX_VENUES]
    print(f"\nProcessing {len(winery_urls)} wineries...\n")

    results = []

    for i, url in enumerate(winery_urls):
        print(f"[{i+1}/{len(winery_urls)}] {url}")

        # Step 2: Scrape winery detail page
        venue = scrape_winery_detail(url)
        if not venue or not venue['name']:
            print("  [SKIP] Could not parse venue info")
            continue

        # Set zone priority
        venue['zone_priority'] = get_zone_priority(venue['city'])


        print(f"  Name: {venue['name']}")
        print(f"  City: {venue['city']}")
        print(f"  Website: {venue['website']}")
        print(f"  Facebook: {venue['facebook']}")
        print(f"  Instagram: {venue['instagram']}")
        print(f"  Zone: {venue['zone_priority']}")

        # Push venue to sheet; contacts must use the id the sheet assigned
        resp = push_to_sheet('add_venue', dict(venue))
        if resp.get('status') != 'ok' or not resp.get('venue_id'):
            print(f"  [ERROR] add_venue failed: {resp.get('message', resp)} — skipping this venue's contacts")
            continue
        venue['venue_id'] = resp['venue_id']
        print(f"  Venue ID: {venue['venue_id']}" + (" (already in sheet)" if resp.get('duplicate') else ''))

        # Step 3: Scrape website for emails
        emails = scrape_website_emails(venue['website'])

        # Also try Facebook about page (not the venue's own site: weaker evidence)
        fb_emails = [fe for fe in scrape_facebook_email(venue['facebook']) if fe not in emails]

        print(f"  Emails found: {emails + fb_emails}")

        # Step 4: policy check, verify, push each email
        for email in emails:
            print(f"  {email}: {save_email(venue, email, 'website', True)}")
        for email in fb_emails:
            print(f"  {email}: {save_email(venue, email, 'facebook', False)}")
        emails = emails + fb_emails

        results.append({
            'venue': venue['name'],
            'city': venue['city'],
            'emails': emails,
            'zone': venue['zone_priority']
        })

        print()
        time.sleep(2)  # Be polite to servers

    # Summary
    print("=" * 50)
    print("SCRAPE COMPLETE")
    print("=" * 50)
    total_emails = sum(len(r['emails']) for r in results)
    print(f"Venues scraped: {len(results)}")
    print(f"Emails found: {total_emails}")
    for r in results:
        print(f"  {r['venue']} ({r['city']}) — {len(r['emails'])} emails — zone: {r['zone']}")


if __name__ == "__main__":
    # Allow overriding max venues from command line
    if len(sys.argv) > 1:
        try:
            MAX_VENUES = int(sys.argv[1])
        except:
            pass
    main()
