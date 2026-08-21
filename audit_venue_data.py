#!/usr/bin/env python3
"""Audit existing venue rows for obvious category and website mistakes.

Default is read-only and writes venue-data-audit.csv. Use --apply-safe to make only
high-confidence repairs:
  * restaurant -> obvious hotel/country/private/yacht club/wine bar category fixes
  * clear known directory/social URLs and quarantine the row as needs_review
Unrelated-domain mismatches are reported but not auto-cleared.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

from venue_quality import canonical_category, is_blocked_domain, website_match_score

DEFAULT_API = "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"
SAFE_CATEGORY_FIXES = {'hotel','country_club','private_club','yacht_club','wine_bar','winery'}


def get_json(url: str) -> dict:
    with urlopen(url, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def update(api: str, venue_id: str, field: str, value: str) -> bool:
    q = urlencode({'action':'update_venue','venue_id':venue_id,'field':field,'value':value})
    try:
        data = get_json(api + '?' + q)
        return data.get('status') == 'ok'
    except Exception:
        return False


def audit_venue(v: dict) -> list[dict]:
    issues = []
    vid = str(v.get('venue_id',''))
    name = str(v.get('name',''))
    current = str(v.get('category','') or 'other').lower().replace(' ','_')
    suggested = canonical_category(str(v.get('category','')), name)
    if suggested != 'other' and suggested != current:
        # Strong identity fixes are especially important for legacy REST rows.
        if current in {'restaurant','rest','other','recreation'} or suggested in SAFE_CATEGORY_FIXES:
            issues.append({'venue_id':vid,'name':name,'issue':'category','current':current,'suggested':suggested,'confidence':'high'})

    website = str(v.get('website','') or '').strip()
    if website:
        if is_blocked_domain(website):
            issues.append({'venue_id':vid,'name':name,'issue':'website_directory','current':website,'suggested':'','confidence':'high'})
        else:
            score = website_match_score(name, website)
            if score < 6:
                issues.append({'venue_id':vid,'name':name,'issue':'website_mismatch','current':website,'suggested':'recheck','confidence':'review'})
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
    issues = []
    for v in venues:
        issues.extend(audit_venue(v))

    out = Path(args.output)
    with out.open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=['venue_id','name','issue','current','suggested','confidence'])
        w.writeheader(); w.writerows(issues)

    fixed = 0
    if args.apply_safe:
        for issue in issues:
            if issue['confidence'] != 'high':
                continue
            vid = issue['venue_id']
            if issue['issue'] == 'category' and issue['suggested'] in SAFE_CATEGORY_FIXES:
                if update(args.api, vid, 'category', issue['suggested']):
                    fixed += 1
            elif issue['issue'] == 'website_directory':
                ok1 = update(args.api, vid, 'website', '')
                ok2 = update(args.api, vid, 'status', 'needs_review') if ok1 else False
                if ok1 and ok2:
                    fixed += 1

    cat_count = sum(i['issue']=='category' for i in issues)
    web_bad = sum(i['issue']=='website_directory' for i in issues)
    web_review = sum(i['issue']=='website_mismatch' for i in issues)
    print(f'Audited {len(venues)} venues')
    print(f'Category fixes flagged: {cat_count}')
    print(f'Known directory/social websites flagged: {web_bad}')
    print(f'Other website mismatches for review: {web_review}')
    if args.apply_safe:
        print(f'Safe fixes applied: {fixed}')
    print(f'Report: {out.resolve()}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
