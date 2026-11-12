#!/usr/bin/env python3
"""Pool repair: good venues the planner skips because of bad data get researched and fixed.

Nov 11 2026 (Alex: "did you fix this so next time we do sweeps it will show up?"). About 700 DC/MD/VA
restaurants, hotels, clubs and wineries sat unused for months: the old Google Maps discovery saved query
words as the city ("historic place to eat in"), chain homepages as websites (marriott.com), geocodes in
other states (Reston at 43 hours), and the taste rules skip upscale places that aren't European
(Old Ebbitt Grill, The Dabney, Kingbird). Nothing ever went back to them. Now every burn round:

    repair_pool.py list --out LIST.json [--limit 60]     which rows need research (build_batch's own skips)
    (a Claude session follows NIGHT_REPAIR.md: WebSearch, writes OUT.json)
    repair_pool.py apply OUT.json [--apply]               write the fixes, backup + read-back

apply: websites/closures via save_websites.py; city/state/address + drive time from Pasadena (Nominatim +
OSRM); a never-run needs_review venue confirmed open, in the region, within 2 hours with its own site ->
untouched; not a venue -> dismissed; an "upscale" rating -> notes "Upscale checked <date>: N" +
upscale_score (build_batch lets 4-5 past the European-only gate). Every researched row gets
"Repair checked <date>" in its notes, so it isn't listed again for REPAIR_RECHECK_DAYS (30).
"""
import argparse, collections, fcntl, glob, json, os, re, subprocess, sys, time, urllib.parse
from datetime import date, datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from night_save import api, detail  # noqa: E402

HOME = (-76.5713, 39.1076)   # Pasadena MD
REGION = ('DC', 'MD', 'VA')
REAL_STAGE = {'restaurant', 'fine_dining', 'bistro', 'hotel', 'luxury_hotel', 'inn', 'country_club', 'private_club',
              'club', 'golf_club', 'yacht_club', 'winery', 'vineyard', 'wine_bar', 'event_venue', 'event', 'estate'}
DATA_REASONS = ('blank/malformed city', 'bare brand homepage as website', "website not verified as the venue's own",
                'location not trustworthy', 'junk website', 'too far')
TASTE_REASON = 'no prime evidence (generic restaurant, chain or non-European cuisine)'
RECHECK_DAYS = int(os.environ.get('REPAIR_RECHECK_DAYS', '30'))
TODAY = date.today().isoformat()
CHECKED_RX = re.compile(r'(?i)repair checked (\d{4}-\d{2}-\d{2})')
LOCK = '/tmp/repair_pool_nominatim.lock'


def cat_of(v):
    return str(v.get('category') or '').lower().replace(' ', '_')


def recently_checked(v):
    m = CHECKED_RX.search(str(v.get('notes') or ''))
    return bool(m and datetime.strptime(m.group(1), '%Y-%m-%d').date() > date.today() - timedelta(days=RECHECK_DAYS))


def ever_run():
    ran = set()
    for f in glob.glob(str(HERE / 'reports/runs/*.jsonl')):
        for line in open(f, errors='replace'):
            m = re.search(r'"venue_id":\s*"([^"]+)"', line)
            if m:
                ran.add(m.group(1))
    return ran


def cmd_list(a):
    dump = a.out + '.bbdump.json'
    env = dict(os.environ, BB_DUMP=dump)
    r = subprocess.run([str(HERE / 'build_batch.sh'), '--total', '8', '--dry-run'], cwd=HERE, env=env,
                       capture_output=True, text=True, timeout=900)
    if not os.path.exists(dump):
        sys.exit('build_batch.sh left no dump: ' + (r.stderr or r.stdout)[-300:])
    d = json.load(open(dump))
    os.remove(dump)
    vs = {str(v.get('venue_id')): v for v in api({'action': 'venues'}, timeout=180).get('venues') or []}
    ran = ever_run()
    picks, why = [], collections.Counter()

    def add(vid, reason):
        v = vs.get(vid)
        if not v or v.get('state') not in REGION or cat_of(v) not in REAL_STAGE or recently_checked(v):
            return
        if reason == 'too far':   # only drive times that can't be right inside DC/MD/VA, or with no street address
            try:
                dm = float(v.get('drive_minutes') or 0)
            except ValueError:
                dm = 0
            if dm <= 240 and re.search(r'\d', str(v.get('address') or '')):
                return
        if reason == TASTE_REASON and 'upscale checked' in str(v.get('notes') or '').lower():
            return
        picks.append({k: v.get(k) for k in ('venue_id', 'name', 'category', 'city', 'state', 'address', 'website')}
                     | {'reason': reason, 'rate': reason == TASTE_REASON, 'promote': v.get('status') == 'needs_review'})
        why[reason] += 1

    for reason in DATA_REASONS + (TASTE_REASON,):
        for it in d['skips'].get(reason, []):
            m = re.search(r'\[([^\]]+)\]', it)
            if m:
                add(m.group(1), reason)
    seen = {p['venue_id'] for p in picks}
    for vid, v in vs.items():   # discovery finds nobody ever confirmed
        if v.get('status') == 'needs_review' and vid not in ran and vid not in seen:
            add(vid, 'needs_review, never run')
    picks = picks[:a.limit]
    json.dump({'venues': picks}, open(a.out, 'w'), indent=1)
    print(f'{len(picks)} venues to research -> {a.out} ({dict(why)})')


def curl_json(url):
    out = subprocess.run(['curl', '-s', '--max-time', '30', '-A', 'gig-outreach-repair/1.0', url],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except ValueError:
        return None


def drive(address):
    with open(LOCK, 'w') as lk:   # one Nominatim request a second
        fcntl.flock(lk, fcntl.LOCK_EX)
        g = curl_json('https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=us&q='
                      + urllib.parse.quote(address))
        time.sleep(1.1)
    if not g:
        return None
    r = curl_json(f'https://router.project-osrm.org/route/v1/driving/{HOME[0]},{HOME[1]};{g[0]["lon"]},{g[0]["lat"]}?overview=false')
    if not r or r.get('code') != 'Ok':
        return None
    return round(r['routes'][0]['distance'] / 1609.34, 1), round(r['routes'][0]['duration'] / 60)


def cmd_apply(a):
    rows = json.load(open(a.findings))
    rows = rows.get('venues', rows) if isinstance(rows, dict) else rows
    asked = {}
    if a.list and os.path.exists(a.list):
        asked = {p['venue_id']: p for p in json.load(open(a.list)).get('venues', [])}
    n = collections.Counter()
    sites = [r for r in rows if not r.get('not_a_venue') and r.get('confidence') in ('high', 'medium')]
    tmp = a.findings + '.sites.json'
    json.dump(sites, open(tmp, 'w'))
    sw = subprocess.run(['/usr/bin/python3', str(HERE / 'save_websites.py'), tmp] + (['--apply'] if a.apply else []),
                        cwd=HERE, capture_output=True, text=True, timeout=3600)
    print((sw.stdout.strip().splitlines() or ['save_websites: no output'])[-1])
    os.remove(tmp)
    bk = open(HERE / f'reports/repair/repair-pool-{TODAY}-backup.jsonl', 'a')
    for r in rows:
        vid = r.get('venue_id')
        v = ((detail(vid) or {}).get('venue') or {}) if vid else {}
        if v.get('status') not in ('untouched', 'needs_review'):
            n['skip (status)'] += 1
            continue
        change, sure = {}, r.get('confidence') in ('high', 'medium') and not r.get('closed')
        if r.get('not_a_venue') and r.get('confidence') in ('high', 'medium'):
            change['status'] = 'dismissed'
        elif sure:
            city, st, addr = (r.get('city') or '').strip(), (r.get('state') or '').strip().upper(), (r.get('address') or '').strip()
            if city and len(st) == 2:
                want = {'city': city, 'state': st}
                if re.search(r'\d', addr):
                    want['address'] = addr
                change.update({k: x for k, x in want.items() if str(v.get(k) or '').strip() != x})
                dm = drive(addr or f'{city}, {st}')
                if dm:
                    change['distance_miles'], change['drive_minutes'] = dm
                if (v.get('status') == 'needs_review' and (asked.get(vid) or {}).get('promote', True)
                        and r.get('confidence') == 'high' and r.get('website') and st in REGION and dm and dm[1] <= 120):
                    change['status'] = 'untouched'
        notes = str(v.get('notes') or '')
        add = []
        try:
            u = int(r.get('upscale'))
        except (TypeError, ValueError):
            u = None
        if u and 'upscale checked' not in notes.lower():
            add.append(f"Upscale checked {TODAY}: {u} ({str(r.get('why') or '')[:80]})")
            change['upscale_score'] = u
        if not CHECKED_RX.search(notes):
            add.append(f'Repair checked {TODAY}')
        else:
            notes = CHECKED_RX.sub(f'Repair checked {TODAY}', notes)
        change['notes'] = ' | '.join([x for x in [notes] + add if x])
        if not a.apply:
            n['would change'] += 1
            print(' ', vid, str(r.get('name'))[:32], {k: x for k, x in change.items() if k != 'notes'})
            continue
        bk.write(json.dumps(v) + '\n'); bk.flush()
        for k, x in change.items():
            api({'action': 'update_venue', 'venue_id': vid, 'field': k, 'value': x})
        back = ((detail(vid) or {}).get('venue') or {})
        ok = all(str(back.get(k) or '').strip() == str(x).strip() for k, x in change.items() if k in ('city', 'state', 'status'))
        n[('dismissed' if change.get('status') == 'dismissed' else 'promoted' if change.get('status') == 'untouched'
           else 'fixed') if ok else 'error'] += 1
    print('repair_pool apply:', dict(n), '' if a.apply else '(preview)')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    l = sub.add_parser('list'); l.add_argument('--out', required=True); l.add_argument('--limit', type=int, default=60)
    ap = sub.add_parser('apply'); ap.add_argument('findings'); ap.add_argument('--list'); ap.add_argument('--apply', action='store_true')
    a = p.parse_args()
    cmd_list(a) if a.cmd == 'list' else cmd_apply(a)


if __name__ == '__main__':
    main()
