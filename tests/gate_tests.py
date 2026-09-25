#!/usr/bin/env python3
"""Offline tests for the run gate: mark_step.sh + verify_run.sh.

Builds a fake reports/ tree (ledger, run logs, web-coverage files, candidate
log, miss audit, sheet fixtures) in a temp dir and runs the real scripts with
REPORTS_DIR / VERIFY_SHEET_FIXTURE_DIR pointed at it. No network, no sheet.

    /usr/bin/python3 tests/gate_tests.py
"""
import datetime
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = os.path.join(ROOT, 'mark_step.sh')
VERIFY = os.path.join(ROOT, 'verify_run.sh')
RID = 'run-test-1'
LOG_DATE = '2026-09-20'   # well before "now", so marks are after DONE

VENUES = [
    {'venue_id': 'V-1', 'name': 'Venue One', 'website': 'https://venueone.com', 'state': 'MD'},
    {'venue_id': 'V-2', 'name': 'Venue Two', 'website': 'https://venuetwo.com', 'state': 'VA'},
    {'venue_id': 'V-3', 'name': 'Venue Three', 'website': 'https://venuethree.com', 'state': 'DC'},
]
GOOD_MARKS = {
    'web': '2 emails, contact form https://example.com/contact',
    'fb': 'facebook.com/venuepage checked About',
    'ig': 'instagram.com/venuepage, no email in bio',
    'linkedin': '6 people, 2 relevant',
    'apollo': '1 enriched',
    'status': 'open, hours on site',
    'contacts': '1 added, 0 pending',
}


def _dump(obj, path):
    with open(path, 'w') as f:
        json.dump(obj, f)


def step_lines(vid, dom, **over):
    lines = {
        'web': f'[STEP] {vid} web ok via=chrome pages=9 emails=2 saved=1 rejected=1 form=https://{dom}/contact',
        'social': f'[STEP] {vid} social ok fb=https://www.facebook.com/{vid.lower()} ig=none',
        'apollo': f'[STEP] {vid} apollo ok domain_results=4 name_results=1 saved=0',
        'linkedin': f'[STEP] {vid} linkedin empty people=0',
        'final': f'[STEP] {vid} final ok status=pipelined valid_contacts=1 new=1',
    }
    lines.update(over)
    return [l for l in lines.values() if l]


def venue_block(v, n, total, done_time, extra=None, over=None):
    dom = v['website'].split('//')[1]
    out = ['', '#' * 20 + f" VENUE [{n}/{total}]: {v['name']} " + '#' * 20,
           f" PIPELINE: {v['name']} ({v['venue_id']})",
           '========== STEP 1: Website Scrape ==========',
           f"  ✓ Added and verified: Jane Doe <jane.doe@{dom}>"]
    out += extra or []
    out += step_lines(v['venue_id'], dom, **(over or {}))
    out += [f" DONE: {v['name']} | 5 min | {done_time}"]
    return out


def coverage(v, pages_ok=True):
    base = v['website']
    pages = [{'url': base + '/', 'depth': 0, 'ok': True, 'emails': []}]
    for p in ('contact', 'about', 'private-events', 'our-team'):
        pages.append({'url': f'{base}/{p}', 'depth': 1, 'ok': pages_ok, 'emails': []})
    return {'venue_id': v['venue_id'], 'base': base + '/', 'pages': pages,
            'discovered_pages': [p['url'] for p in pages],
            'coverage': {'successful_page_count': sum(1 for p in pages if p['ok']), 'visited_page_count': len(pages)},
            'coverage_generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}


def detail(v, status='pipelined', contacts=None, state=None):
    dom = v['website'].split('//')[1]
    if contacts is None:
        contacts = [{'contact_id': 'C-1', 'name': 'Jane Doe', 'email': f'jane.doe@{dom}', 'verified': 'valid'}]
    return {'status': 'ok', 'venue': {'venue_id': v['venue_id'], 'name': v['name'], 'status': status,
                                      'state': state or v['state'], 'website': v['website']},
            'contacts': contacts}


class Gate:
    """A throwaway reports/ tree with a complete, clean 2-batch run."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix='gate-')
        self.reports = os.path.join(self.dir, 'reports')
        self.runs = os.path.join(self.reports, 'runs')
        self.sheet = os.path.join(self.dir, 'sheet')
        for d in (self.runs, os.path.join(self.reports, 'web-coverage'), self.sheet):
            os.makedirs(d)
        self.env = dict(os.environ, REPORTS_DIR=self.reports, VERIFY_SHEET_FIXTURE_DIR=self.sheet,
                        MARK_BY='gate-test', RUN_ID=RID)
        self.env.pop('ERR_LOG', None)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def sh(self, *args, check=False):
        r = subprocess.run(['bash', *args], capture_output=True, text=True, env=self.env)
        if check and r.returncode not in (0, 1, 3):
            raise AssertionError(f'{args} exited {r.returncode}: {r.stderr}')
        return r

    def write(self, rel, text):
        p = os.path.join(self.reports, rel)
        with open(p, 'w') as f:
            f.write(text)
        return p

    def build_clean(self):
        b1, b2 = os.path.join(self.dir, 'b1.json'), os.path.join(self.dir, 'b2.json')
        _dump(VENUES[:2], b1)
        _dump(VENUES[2:], b2)
        assert self.sh(MARK, '--batch', b1, RID).returncode == 0
        assert self.sh(MARK, '--batch', b2, RID, '--append').returncode == 0
        self.logs = {
            f'{RID}.log': [f'=== Pipeline started {LOG_DATE} 10:00:00 ===', 'BATCH MODE: 2 venues']
            + venue_block(VENUES[0], 1, 2, '10:05:00') + venue_block(VENUES[1], 2, 2, '10:10:00')
            + ['=== BATCH COMPLETE ===', '[10:11:00] [STEP] V-1 postcheck skipped reason=has_contacts valid=1',
               '[10:11:01] [STEP] V-2 postcheck skipped reason=has_contacts valid=1'],
            f'{RID}.b2.log': [f'=== Pipeline started {LOG_DATE} 11:00:00 ===', 'BATCH MODE: 1 venues']
            + venue_block(VENUES[2], 1, 1, '11:05:00')
            + ['=== BATCH COMPLETE ===', '[11:06:00] [STEP] V-3 postcheck skipped reason=has_contacts valid=1'],
        }
        self.flush_logs()
        for v in VENUES:
            self.write(f"web-coverage/{v['venue_id']}.json", json.dumps(coverage(v)))
            self.set_detail(v)
        # written directly (fast); verify_run re-checks every note with mark_step's rules
        now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        with open(os.path.join(self.runs, f'{RID}.jsonl'), 'a') as f:
            for v in VENUES:
                for step, note in GOOD_MARKS.items():
                    f.write(json.dumps({'type': 'venue', 'venue_id': v['venue_id'], 'step': step, 'status': 'done',
                                        'note': note, 'ts': now, 'by': 'gate-test', 'run_id': RID}) + '\n')
        with open(os.path.join(self.runs, f'{RID}.misses.jsonl'), 'w') as f:
            for v in VENUES:
                f.write(json.dumps({'venue_id': v['venue_id'], 'kind': 'audited'}) + '\n')
        self.report = self.write('2026-09-25_04-00.html', '<html><body><h1>Report</h1></body></html>')
        assert self.sh(MARK, '--run', 'taste_review', 'done', 'no new votes since run-test-0').returncode == 0
        assert self.sh(MARK, '--run', 'report', 'done', 'reports/2026-09-25_04-00.html').returncode == 0

    def flush_logs(self):
        for name, lines in self.logs.items():
            with open(os.path.join(self.runs, name), 'w') as f:
                f.write('\n'.join(lines) + '\n')

    def set_detail(self, v, **kw):
        with open(os.path.join(self.sheet, f"{v['venue_id']}.json"), 'w') as f:
            json.dump(detail(v, **kw), f)

    def verify(self, *extra):
        r = self.sh(VERIFY, RID, '--json', *extra, check=True)
        try:
            return r.returncode, json.loads(r.stdout)
        except json.JSONDecodeError:
            raise AssertionError(f'verify_run output not JSON (rc {r.returncode}): {r.stdout[-500:]} {r.stderr[-500:]}')

    def kinds(self, d):
        return sorted({(x['venue_id'], x['kind'], x['step']) for x in d['review']})


class MarkStepTests(unittest.TestCase):
    def setUp(self):
        self.g = Gate()
        b = os.path.join(self.g.dir, 'b.json')
        _dump(VENUES, b)
        self.assertEqual(self.g.sh(MARK, '--batch', b, RID).returncode, 0)

    def tearDown(self):
        self.g.cleanup()

    def mark(self, *a):
        return self.g.sh(MARK, *a).returncode

    def test_trivial_notes_rejected(self):
        for note in ('done', 'ok', 'checked', 'none', ''):
            self.assertNotEqual(self.mark('V-1', 'web', 'done', note), 0, note)

    def test_linkedin_needs_linkedin_evidence(self):
        self.assertNotEqual(self.mark('V-1', 'linkedin', 'done', 'Apollo 0 domain, 0 company'), 0)
        self.assertEqual(self.mark('V-1', 'linkedin', 'done', '7 people, 2 relevant'), 0)

    def test_contacts_done_with_zero_rejected(self):
        self.assertNotEqual(self.mark('V-1', 'contacts', 'done', '0 contacts, venue closed'), 0)
        self.assertEqual(self.mark('V-1', 'contacts', 'BLOCKED', 'nothing on site, FB, IG, Apollo or LinkedIn'), 0)

    def test_blocked_needs_reason(self):
        self.assertNotEqual(self.mark('V-1', 'linkedin', 'BLOCKED', 'wall'), 0)
        self.assertEqual(self.mark('V-1', 'linkedin', 'BLOCKED', 'login wall on page 1'), 0)

    def test_batch_limit_and_append(self):
        big = os.path.join(self.g.dir, 'big.json')
        _dump([{'venue_id': f'X-{i}'} for i in range(9)], big)
        self.assertNotEqual(self.g.sh(MARK, '--batch', big, RID, '--append').returncode, 0)
        ok = os.path.join(self.g.dir, 'ok.json')
        _dump([{'venue_id': 'X-1'}, {'venue_id': 'V-1'}], ok)
        r = self.g.sh(MARK, '--batch', ok, RID, '--append')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('batch 2 registered 1', r.stdout)
        with open(os.path.join(self.g.runs, f'{RID}.jsonl')) as fh:
            rows = [json.loads(l) for l in fh]
        self.assertTrue(all(r.get('by') == 'gate-test' for r in rows))
        self.assertEqual({r['batch'] for r in rows if r.get('step') == 'registered'}, {1, 2})

    def test_plan_batches_all_appended_under_one_run(self):
        env = dict(self.g.env)
        env.pop('RUN_ID')
        for n in range(1, 8):            # 7 batches of up to 8 = a 50-venue run
            b = os.path.join(self.g.dir, f'batch_{n:02d}.json')
            _dump([{'venue_id': f'P-{n}-{k}', 'name': f'Plan {n} {k}'} for k in range(1, 9 if n < 7 else 3)], b)
            r = subprocess.run(['bash', MARK, '--batch', b, 'run-plan-1', '--append', '--new-run'],
                               capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.g.runs, 'run-plan-1.jsonl')) as fh:
            rows = [json.loads(l) for l in fh]
        reg = [r for r in rows if r.get('step') == 'registered']
        self.assertEqual(len(reg), 50)
        self.assertEqual(sorted({r['batch'] for r in reg}), list(range(1, 8)))
        r = subprocess.run(['bash', VERIFY, 'run-plan-1', '--json', '--no-sheet'], capture_output=True, text=True, env=env)
        d = json.loads(r.stdout)
        self.assertEqual(len(d['batches']), 7)
        self.assertEqual(len(d['venues']), 50)

    def test_new_run_refused_while_current_unfinished(self):
        b = os.path.join(self.g.dir, 'n.json')
        _dump([{'venue_id': 'N-1'}], b)
        env = dict(self.g.env)
        env.pop('RUN_ID')
        r = subprocess.run(['bash', MARK, '--batch', b, 'run-test-2'], capture_output=True, text=True, env=env)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not finished', r.stderr)


class VerifyRunTests(unittest.TestCase):
    def setUp(self):
        self.g = Gate()
        self.g.build_clean()

    def tearDown(self):
        self.g.cleanup()

    def embed_and_verify(self):
        r = self.g.sh(VERIFY, RID, '--embed-report')
        self.assertIn(r.returncode, (0, 1), r.stderr)
        return self.g.verify()

    def test_clean_run_is_clean_after_embedding(self):
        rc, d = self.g.verify()
        self.assertEqual(rc, 1)          # report block not embedded yet
        self.assertIn(('(run)', 'report'), [(m[0], m[1]) for m in d['missing']])
        rc, d = self.embed_and_verify()
        self.assertEqual(d['missing'], [])
        self.assertEqual(d['review'], [], d['review'])
        self.assertTrue(d['clean'])
        self.assertEqual(rc, 0)
        self.assertTrue(d['verdict'].startswith('RUN CLEAN'), d['verdict'])
        self.assertIn('miss rate 0.0%', d['verdict'])
        html = open(self.g.report).read()
        self.assertEqual(html.count('<!-- verify_run:begin -->'), 1)
        self.g.sh(VERIFY, RID, '--embed-report')          # idempotent
        self.assertEqual(open(self.g.report).read().count('<!-- verify_run:begin -->'), 1)

    def test_text_output_ends_with_verdict(self):
        self.embed_and_verify()
        out = self.g.sh(VERIFY, RID).stdout.strip().split('\n')
        self.assertTrue(out[-1].startswith('RUN CLEAN'), out[-1])

    def test_stale_block_is_missing(self):
        self.embed_and_verify()
        self.g.set_detail(VENUES[1], status='needs_review', contacts=[])
        rc, d = self.g.verify()
        self.assertIn('stale', ' '.join(m[2] for m in d['missing']))
        self.assertFalse(d['clean'])

    def test_curl_only_is_a_coverage_gap(self):
        L = self.g.logs[f'{RID}.log']
        i = L.index('[STEP] V-2 web ok via=chrome pages=9 emails=2 saved=1 rejected=1 form=https://venuetwo.com/contact')
        L[i] = '[STEP] V-2 web failed via=curl reason=chrome_js_failed emails=1 form=none'
        self.g.flush_logs()
        rc, d = self.embed_and_verify()
        self.assertIn(('V-2', 'coverage_gap', 'website'), self.g.kinds(d))
        self.assertFalse(d['clean'])
        self.assertIn('coverage gap', d['verdict'])
        self.assertEqual(d['missing'], [])  # the manual web mark satisfies the gate

    def test_failed_step_without_manual_mark_is_missing(self):
        L = self.g.logs[f'{RID}.log']
        i = next(n for n, l in enumerate(L) if l.startswith('[STEP] V-1 apollo'))
        L[i] = '[STEP] V-1 apollo failed reason=org_lookup_crash'
        self.g.flush_logs()
        ledger = os.path.join(self.g.runs, f'{RID}.jsonl')
        rows = [l for l in open(ledger) if not ('"V-1"' in l and '"apollo"' in l)]
        open(ledger, 'w').writelines(rows)
        rc, d = self.g.verify()
        self.assertEqual(rc, 1)
        self.assertTrue(any(m[0] == 'V-1' and m[1] == 'apollo' and 'org_lookup_crash' in m[2] for m in d['missing']))

    def test_missing_apollo_name_count_is_a_gap(self):
        L = self.g.logs[f'{RID}.log']
        i = next(n for n, l in enumerate(L) if l.startswith('[STEP] V-1 apollo'))
        L[i] = '[STEP] V-1 apollo ok domain_results=4'
        self.g.flush_logs()
        rc, d = self.embed_and_verify()
        self.assertIn(('V-1', 'coverage_gap', 'apollo_name'), self.g.kinds(d))

    def test_header_only_log_is_not_evidence(self):
        v = VENUES[0]
        self.g.logs[f'{RID}.log'] = [f'=== Pipeline started {LOG_DATE} 10:00:00 ===',
                                     f" PIPELINE: {v['name']} ({v['venue_id']})",
                                     '========== STEP 1: Website Scrape ==========',
                                     '========== STEP 2: Social Media Scrape ==========',
                                     '========== STEP 3: Apollo API ==========',
                                     '========== STEP 4: LinkedIn + Apollo API ==========',
                                     f" DONE: {v['name']} | 5 min | 10:05:00", '=== BATCH COMPLETE ===']
        self.g.flush_logs()
        rc, d = self.g.verify()
        gaps = {x['step'] for x in d['review'] if x['venue_id'] == 'V-1' and x['kind'] == 'coverage_gap'}
        self.assertTrue({'website', 'social', 'apollo', 'linkedin'} <= gaps, gaps)
        self.assertFalse(d['clean'])

    def test_traceback_in_step_is_flagged(self):
        L = self.g.logs[f'{RID}.log']
        i = L.index('========== STEP 1: Website Scrape ==========')
        L[i + 1:i + 1] = ['========== STEP 3: Apollo API ==========', 'Traceback (most recent call last):',
                          '  File "<stdin>", line 3, in <module>', 'json.decoder.JSONDecodeError: Expecting value']
        self.g.flush_logs()
        rc, d = self.embed_and_verify()
        self.assertIn(('V-1', 'python_error', 'apollo'), self.g.kinds(d))

    def test_closed_venue_skip_passes_gate_but_needs_review(self):
        L = self.g.logs[f'{RID}.b2.log']
        v = VENUES[2]
        self.g.logs[f'{RID}.b2.log'] = [L[0], L[1], f" PIPELINE: {v['name']} ({v['venue_id']})",
                                        '  Website check: HTTP 000 (DNS failure)',
                                        '  Flagging as potentially closed and skipping', '=== BATCH COMPLETE ===']
        self.g.flush_logs()
        self.g.set_detail(v, status='needs_review', contacts=[])
        rc, d = self.embed_and_verify()
        self.assertEqual(d['missing'], [], d['missing'])
        self.assertIn(('V-3', 'venue_skipped', 'final'), self.g.kinds(d))
        self.assertFalse(d['clean'])

    def test_bad_ledger_note_is_missing(self):
        ledger = os.path.join(self.g.runs, f'{RID}.jsonl')
        with open(ledger, 'a') as f:
            f.write(json.dumps({'type': 'venue', 'venue_id': 'V-2', 'step': 'linkedin', 'status': 'done',
                                'note': 'Apollo searched domain(123 results)', 'ts': '2030-01-01 00:00:00'}) + '\n')
        rc, d = self.g.verify()
        self.assertTrue(any(m[0] == 'V-2' and m[1] == 'linkedin' and 'Apollo' in m[2] for m in d['missing']))

    def test_sheet_checks(self):
        v = VENUES[0]
        self.g.set_detail(v, contacts=[{'name': 'Jdoe', 'email': 'jane.doe@venueone.com', 'verified': 'valid'},
                                       {'name': 'Rick Flowers', 'email': 'rick@ricksflowers.com', 'verified': 'valid'}],
                          state='DE')
        L = self.g.logs[f'{RID}.log']
        i = L.index('  ✓ Added and verified: Jane Doe <jane.doe@venueone.com>')
        L.insert(i + 1, '  ✓ Added and verified: Rick <rick@ricksflowers.com>')
        L.insert(i + 1, '  ✓ Added and verified: Lost Person <lost.person@venueone.com>')
        self.g.flush_logs()
        rc, d = self.embed_and_verify()
        k = self.g.kinds(d)
        for want in (('V-1', 'bad_name', 'contacts'), ('V-1', 'off_domain_contact', 'contacts'),
                     ('V-1', 'out_of_area', 'status'), ('V-1', 'save_not_on_sheet', 'contacts')):
            self.assertIn(want, k)

    def test_p4_status_checks(self):
        self.g.set_detail(VENUES[1], status='needs_review')
        rc, d = self.embed_and_verify()
        self.assertIn(('V-2', 'needs_review', 'final'), self.g.kinds(d))
        self.assertIn(('V-2', 'status', 'final'), self.g.kinds(d))

    def test_zero_contact_venue_needs_postcheck_and_google(self):
        L = self.g.logs[f'{RID}.log']
        L[:] = [l for l in L if 'V-2 postcheck' not in l]
        self.g.flush_logs()
        self.g.set_detail(VENUES[1], status='needs_review', contacts=[])
        rc, d = self.g.verify()
        self.assertTrue(any(m[0] == 'V-2' and m[1] == 'postcheck' for m in d['missing']))
        self.assertIn(('V-2', 'coverage_gap', 'google'), self.g.kinds(d))

    def test_postcheck_time_budget_skip_is_a_gap(self):
        L = self.g.logs[f'{RID}.log']
        L[:] = [l.replace('V-2 postcheck skipped reason=has_contacts valid=1', 'V-2 postcheck skipped reason=time_budget')
                for l in L]
        self.g.flush_logs()
        self.g.set_detail(VENUES[1], status='needs_review', contacts=[])
        rc, d = self.g.verify()
        self.assertFalse(any(m[0] == 'V-2' and m[1] == 'postcheck' for m in d['missing']))
        self.assertIn(('V-2', 'coverage_gap', 'postcheck'), self.g.kinds(d))

    def test_misses_counted_and_rated(self):
        with open(os.path.join(self.g.runs, f'{RID}.misses.jsonl'), 'a') as f:
            f.write(json.dumps({'venue_id': 'V-2', 'kind': 'email', 'value': 'events@venuetwo.com',
                                'source_url': 'https://venuetwo.com/weddings', 'pipeline_had': False,
                                'cause_guess': 'page not crawled'}) + '\n')
            f.write(json.dumps({'venue_id': 'V-2', 'kind': 'social', 'value': 'x', 'pipeline_had': True}) + '\n')
        rc, d = self.embed_and_verify()
        self.assertEqual(d['counts']['misses'], 1)
        self.assertIn('1 misses', d['verdict'])
        self.assertIn('miss rate 33.3% (1 of 3 audited venues)', d['verdict'])

    def test_no_miss_audit_is_not_zero(self):
        os.remove(os.path.join(self.g.runs, f'{RID}.misses.jsonl'))
        rc, d = self.embed_and_verify()
        self.assertIn('miss audit not run', d['verdict'])
        self.assertFalse(d['clean'])

    def test_deferred_and_err_log(self):
        L = self.g.logs[f'{RID}.log']
        i = next(n for n, l in enumerate(L) if l.startswith('[STEP] V-2 web'))
        L[i] += ' deferred=2'
        self.g.flush_logs()
        with open(os.path.join(self.g.runs, 'python-errors.log'), 'a') as f:
            f.write(f'[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] pipeline V-1 web (exit 1):\n'
                    '    Traceback (most recent call last):\n    KeyError: x\n')
        rc, d = self.embed_and_verify()
        k = self.g.kinds(d)
        self.assertEqual(d['needs_zb_check'], {'V-2': 2})          # listed, not a review item
        self.assertNotIn('V-2', {x['venue_id'] for x in d['review']})
        self.assertIn('2 email(s) need a ZB check', d['verdict'])
        self.assertIn(('V-1', 'python_error', 'err_log'), k)

    def test_deferred_alone_keeps_run_clean(self):
        L = self.g.logs[f'{RID}.log']
        i = next(n for n, l in enumerate(L) if l.startswith('[STEP] V-2 apollo'))
        L[i] += ' deferred=3'
        self.g.flush_logs()
        self.g.set_detail(VENUES[1], contacts=[{'name': 'Jane Doe', 'email': 'jane.doe@venuetwo.com',
                                                'verified': 'unverified'}])
        rc, d = self.embed_and_verify()
        self.assertTrue(d['clean'], d['review'])
        self.assertIn('3 email(s) need a ZB check', d['verdict'])

    def test_apollo_org_mismatch_needs_manual_check(self):
        L = self.g.logs[f'{RID}.log']
        i = next(n for n, l in enumerate(L) if l.startswith('[STEP] V-1 apollo'))
        L[i] = '[STEP] V-1 apollo empty reason=org_mismatch rejected_orgs=2 domain_search=ok domain_results=0 name_search=ok name_results=2'
        self.g.flush_logs()
        ledger = os.path.join(self.g.runs, f'{RID}.jsonl')
        rows = [l for l in open(ledger) if not ('"V-1"' in l and '"apollo"' in l)]
        open(ledger, 'w').writelines(rows)
        rc, d = self.g.verify()
        self.assertTrue(any(m[0] == 'V-1' and m[1] == 'apollo' and 'org_mismatch' in m[2] for m in d['missing']))

    def test_social_search_blocked_is_a_gap(self):
        L = self.g.logs[f'{RID}.log']
        i = next(n for n, l in enumerate(L) if l.startswith('[STEP] V-1 social'))
        L[i] = '[STEP] V-1 social ok fb=found ig=none fb_search=website ig_search=blocked:google_captcha emails=0'
        self.g.flush_logs()
        rc, d = self.embed_and_verify()
        self.assertIn(('V-1', 'coverage_gap', 'instagram'), self.g.kinds(d))
        self.assertNotIn(('V-1', 'coverage_gap', 'facebook'), self.g.kinds(d))

    def test_dead_batch_is_missing(self):
        L = self.g.logs[f'{RID}.b2.log']
        self.g.logs[f'{RID}.b2.log'] = [l for l in L if 'V-3 final' not in l and 'BATCH COMPLETE' not in l
                                        and 'DONE:' not in l]
        self.g.flush_logs()
        rc, d = self.g.verify()
        self.assertEqual(rc, 1)
        self.assertIn(('V-3', 'final'), [(m[0], m[1]) for m in d['missing']])
        # a resume log for the batch finishes it
        v = VENUES[2]
        self.g.logs[f'{RID}.resume1.log'] = [f'=== Pipeline started {LOG_DATE} 12:00:00 ===',
                                             f" PIPELINE: {v['name']} ({v['venue_id']})",
                                             f"[STEP] V-3 final ok status=pipelined valid_contacts=1 new=0",
                                             f" DONE: {v['name']} | 1 min | 12:01:00", '=== BATCH COMPLETE ===']
        self.g.flush_logs()
        rc, d = self.g.verify()
        self.assertNotIn(('V-3', 'final'), [(m[0], m[1]) for m in d['missing']])

    def test_id_fix_alias_is_followed(self):
        # the batch said V-2 but the pipeline switched to the sheet's real id
        L = self.g.logs[f'{RID}.log']
        L[:] = [l.replace('[STEP] V-2 ', '[STEP] V-22 ') for l in L]
        i = next(n for n, l in enumerate(L) if 'PIPELINE: Venue Two' in l)
        L.insert(i + 1, "  [ID FIX] 'V-2' not in sheet — using real ID 'V-22' (matched by domain: venuetwo.com)")
        self.g.flush_logs()
        os.rename(os.path.join(self.g.sheet, 'V-2.json'), os.path.join(self.g.sheet, 'V-22.json'))
        rc, d = self.embed_and_verify()
        self.assertEqual(d['missing'], [], d['missing'])
        self.assertEqual(d['id_fixes'], {'V-2': 'V-22'})
        self.assertTrue(d['clean'], d['review'])

    def test_json_and_embed_together_and_missing_kinds(self):
        ledger = os.path.join(self.g.runs, f'{RID}.jsonl')
        rows = [l for l in open(ledger) if not ('"V-3"' in l and '"linkedin"' in l)]
        open(ledger, 'w').writelines(rows)
        # An automated step that proved itself (linkedin empty) needs no manual mark.
        r = self.g.sh(VERIFY, RID, '--json', '--embed-report', self.g.report)
        d = json.loads(r.stdout)
        self.assertIn('<!-- verify_run:begin -->', open(self.g.report).read())
        self.assertEqual([m for m in d['missing_items'] if m['venue_id'] == 'V-3'], [])
        # A failed one does, and the missing item says so.
        for name in self.g.logs:
            self.g.logs[name] = [l.replace('[STEP] V-3 linkedin empty people=0',
                                           '[STEP] V-3 linkedin failed reason=login_wall')
                                 for l in self.g.logs[name]]
        self.g.flush_logs()
        r = self.g.sh(VERIFY, RID, '--json', '--embed-report', self.g.report)
        d = json.loads(r.stdout)
        items = [m for m in d['missing_items'] if m['venue_id'] == 'V-3']
        self.assertTrue(items, d['missing_items'])
        self.assertEqual([m['kind'] for m in items], ['auto_failed_unresolved'], items)
        self.assertTrue(all(m['needs_manual_mark'] for m in items), items)

    def test_crawl_blocked_throttled_and_missing_kinds(self):
        v = VENUES[1]
        cov = coverage(v)
        cov['coverage'].update({'blocked': True, 'blocked_reason': 'http_403', 'throttled': False,
                                'page_kinds_missing': ['team'], 'high_priority_unvisited_count': 2})
        cov['high_priority_unvisited'] = ['https://venuetwo.com/private-dining']
        self.g.write(f"web-coverage/{v['venue_id']}.json", json.dumps(cov))
        rc, d = self.embed_and_verify()
        gaps = [x['detail'] for x in d['review'] if x['venue_id'] == 'V-2' and x['kind'] == 'coverage_gap']
        self.assertTrue(any('blocked the crawl' in g for g in gaps), gaps)
        self.assertTrue(any('high-priority' in g for g in gaps), gaps)
        self.assertEqual(d['venues']['V-2']['page_kinds_missing'], ['team'])

    def test_u4_multibatch_log_google_stop_and_final_reasons(self):
        """One appended RUN_LOG across batches (U4 runner): google step lines, last line per
        step wins, a [RUN] STOPPED that is later resumed, final failed/skipped reasons."""
        v1, v2, v3 = VENUES
        L1 = self.g.logs[f'{RID}.log']
        L2 = self.g.logs.pop(f'{RID}.b2.log')
        # V-2 ends with no contact: google must be recorded; first try failed, retry ok
        L1[:] = [l.replace('V-2 final ok status=pipelined valid_contacts=1 new=1',
                           'V-2 final empty status=needs_review valid_contacts=0 new=0') for l in L1]
        i = next(n for n, l in enumerate(L1) if l.startswith('[STEP] V-2 final'))
        L1[i:i] = ['[STEP] V-2 google blocked reason=google_captcha results=0 emails=0 site=none ig=none',
                   '[STEP] V-2 google empty results=6 emails=0 site=venuetwo.com ig=none']
        L1[:] = [l.replace('V-2 postcheck skipped reason=has_contacts valid=1', 'V-2 postcheck empty emails=0') for l in L1]
        self.g.set_detail(v2, status='needs_review', contacts=[])
        # batch 2 is stopped by preflight, then resumed with BATCH MODE again
        stop = ['[RUN] STOPPED: preflight failed between batches']
        self.g.logs[f'{RID}.log'] = L1 + L2[:3] + stop + L2
        self.g.flush_logs()
        os.remove(os.path.join(self.g.runs, f'{RID}.b2.log'))
        for extra in ('batch1.json', 'batch2.json', 'batch1.done', 'batch2.done', 'plan'):   # U4 run files
            self.g.write(f'runs/{RID}.{extra}', '{}')
        rc, d = self.embed_and_verify()
        self.assertNotIn(('V-2', 'coverage_gap', 'google'), self.g.kinds(d))   # last google line wins
        self.assertIn(('V-2', 'needs_review', 'final'), self.g.kinds(d))
        self.assertFalse(any(m[1] == 'run_stopped' for m in d['missing']), d['missing'])
        self.assertEqual(d['logs'], [os.path.join(self.g.runs, f'{RID}.log')])
        # a stop that is NOT followed by a resume leaves the run unfinished
        self.g.logs[f'{RID}.log'] = L1 + L2 + stop
        self.g.flush_logs()
        rc, d = self.g.verify()
        self.assertIn(('(run)', 'run_stopped'), [(m[0], m[1]) for m in d['missing']])
        self.assertEqual([m['kind'] for m in d['missing_items'] if m['step'] == 'run_stopped'], ['run_stopped'])
        # final failed (timeout) needs a pipeline BLOCKED mark; final skipped already_pipelined is a skip
        self.g.logs[f'{RID}.log'] = [l.replace('[STEP] V-1 final ok status=pipelined valid_contacts=1 new=1',
                                               '[STEP] V-1 final failed reason=timeout minutes=25')
                                     .replace('[STEP] V-3 final ok status=pipelined valid_contacts=1 new=1',
                                              '[STEP] V-3 final skipped reason=already_pipelined status=pipelined')
                                     for l in L1 + L2]
        self.g.flush_logs()
        rc, d = self.g.verify()
        self.assertTrue(any(m[0] == 'V-1' and m[1] == 'final' and 'timeout' in m[2] for m in d['missing']))
        self.assertIn(('V-3', 'venue_skipped', 'final'), self.g.kinds(d))
        self.assertNotIn(('V-3', 'status', 'final'), self.g.kinds(d))
        self.assertFalse(any(m[0] == 'V-3' for m in d['missing']), d['missing'])

    def test_strict_exit_code(self):
        os.remove(os.path.join(self.g.runs, f'{RID}.misses.jsonl'))
        self.g.sh(VERIFY, RID, '--embed-report')
        r = self.g.sh(VERIFY, RID, '--strict')
        self.assertEqual(r.returncode, 3, r.stdout[-400:])


if __name__ == '__main__':
    unittest.main(verbosity=2)
