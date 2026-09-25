#!/usr/bin/env python3
"""Audit existing venue rows for obvious category and website mistakes.

Default is read-only and writes venue-data-audit.csv (it also records every
row's current category/website/status, so it doubles as the backup for any
repair). Use --apply-safe to make only high-confidence repairs, and only on
untouched / needs_review rows (contacted and pipelined rows are report-only):
  * a generic category cell (restaurant/rest/other/unknown/blank) -> the strong
    identity in the venue's name (hotel/country/private/yacht club/wine bar/winery)
  * an untouched row whose website is a known directory/social host goes to
    needs_review with a check_status note. Websites are never cleared.
Unrelated-domain mismatches are reported but not auto-changed.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from datetime import date
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from venue_quality import is_blocked_domain, website_match_score
from venue_classifier import classify

DEFAULT_API = os.environ.get('APPS_SCRIPT_URL') or "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
SAFE_CATEGORY_FIXES = {'hotel', 'country_club', 'private_club', 'yacht_club', 'wine_bar', 'winery'}
GENERIC_CATEGORIES = {'restaurant', 'rest', 'other', 'unknown', ''}
EDITABLE_STATUSES = {'untouched', 'needs_review'}


def get_json(url: str) -> dict:
    with urlopen(url, timeout=60) as r:
        return json.loads(r.read().decode('utf-8'))


def update(api: str, venue_id: str, field: str, value: str) -> bool:
    q = urlencode({'action': 'update_venue', 'venue_id': venue_id, 'field': field, 'value': value})
    try:
        data = get_json(api + '?' + q)
        return data.get('status') == 'ok'
    except Exception as e:
        print(f'  update {venue_id} {field} failed: {e}', file=sys.stderr)
        return False


def audit_venue(v: dict) -> list[dict]:
    issues = []
    vid = str(v.get('venue_id', ''))
    name = str(v.get('name', ''))
    status = str(v.get('status', '') or '')
    current = str(v.get('category', '') or '').strip().lower().replace(' ', '_')
    c = classify(name, v.get('category', ''), '', v.get('website', ''), vid)
    suggested = c['primary_category']
    # Only a strong identity in the NAME may replace a generic cell ('Chevy Chase
    # Country Club' filed as restaurant); a sheet slug is never overwritten.
    if (current in GENERIC_CATEGORIES and suggested in SAFE_CATEGORY_FIXES
            and str(c['classification_source']).startswith('name:') and suggested != current):
        conf = 'high' if status in EDITABLE_STATUSES else 'report'
        issues.append({'venue_id': vid, 'name': name, 'status': status, 'issue': 'category',
                       'current': current, 'suggested': suggested, 'confidence': conf})

    website = str(v.get('website', '') or '').strip()
    if website:
        if is_blocked_domain(website):
            conf = 'high' if status == 'untouched' else 'report'
            issues.append({'venue_id': vid, 'name': name, 'status': status,
                           'issue': 'website_directory', 'current': website,
                           'suggested': 'needs_review', 'confidence': conf})
        else:
            score = website_match_score(name, website)
            if score < 6:
                issues.append({'venue_id': vid, 'name': name, 'status': status,
                               'issue': 'website_mismatch', 'current': website,
                               'suggested': 'recheck', 'confidence': 'review'})
    return issues


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--api', default=DEFAULT_API)
    ap.add_argument('--output', default='venue-data-audit.csv')
    ap.add_argument('--apply-safe', action='store_true')
    args = ap.parse_args()

    try:
        data = get_json(args.api + '?action=venues')
    except Exception as e:
        print(f'Could not fetch venue data: {e}', file=sys.stderr)
        return 2
    venues = data.get('venues', [])
    if not venues:
        print('Could not fetch venue data: no venues returned', file=sys.stderr)
        return 2

    issues = []
    for v in venues:
        issues.extend(audit_venue(v))

    out = Path(args.output)
    with out.open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=['venue_id', 'name', 'status', 'issue', 'current',
                                          'suggested', 'confidence'])
        w.writeheader()
        w.writerows(issues)

    fixed = failed = 0
    if args.apply_safe:
        by_id = {str(v.get('venue_id', '')): v for v in venues}
        for issue in issues:
            if issue['confidence'] != 'high':
                continue
            vid = issue['venue_id']
            # Re-read: the row must still be editable and unchanged since the snapshot.
            try:
                live = get_json(args.api + '?' + urlencode({'action': 'venue_detail',
                                                            'venue_id': vid})).get('venue') or {}
            except Exception as e:
                print(f'  {vid}: re-read failed ({e}); skipped', file=sys.stderr)
                failed += 1
                continue
            if live.get('status') not in EDITABLE_STATUSES:
                continue
            if issue['issue'] == 'category':
                if str(live.get('category', '') or '').lower() != str(by_id[vid].get('category', '') or '').lower():
                    continue
                ok = update(args.api, vid, 'category', issue['suggested'])
            elif issue['issue'] == 'website_directory':
                if live.get('status') != 'untouched':
                    continue
                note = f"audit {date.today().isoformat()}: directory website {issue['current']}".replace('|', '/')
                existing = str(live.get('check_status', '') or '').strip()
                ok = (update(args.api, vid, 'check_status', f'{existing}|{note}' if existing else note)
                      and update(args.api, vid, 'status', 'needs_review'))
            else:
                continue
            fixed += ok
            failed += not ok

    cat_count = sum(i['issue'] == 'category' for i in issues)
    web_bad = sum(i['issue'] == 'website_directory' for i in issues)
    web_review = sum(i['issue'] == 'website_mismatch' for i in issues)
    print(f'Audited {len(venues)} venues')
    print(f'Category fixes flagged: {cat_count} '
          f'({sum(i["issue"] == "category" and i["confidence"] == "high" for i in issues)} on editable rows)')
    print(f'Known directory/social websites flagged: {web_bad}')
    print(f'Other website mismatches for review: {web_review}')
    if args.apply_safe:
        print(f'Safe fixes applied: {fixed}' + (f'  FAILED: {failed}' if failed else ''))
    print(f'Report: {out.resolve()}')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
