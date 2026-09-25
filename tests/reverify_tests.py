#!/usr/bin/env python3
"""Offline tests for reverify.sh.

curl and the ZeroBounce guard are replaced by stubs (PATH + ZB_GUARD), so
nothing is paid for and the sheet is never touched. Also checks that the
Apps Script action reverify.sh calls really takes the parameters it sends.

    /usr/bin/python3 tests/reverify_tests.py
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
import urllib.parse
import warnings

warnings.simplefilter('ignore', ResourceWarning)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REVERIFY = os.path.join(ROOT, 'reverify.sh')

FAKE_CURL = r'''#!/usr/bin/python3
import json, os, sys, urllib.parse
d = os.environ['STUB_DIR']
args = sys.argv[1:]
url = next(a for a in args if a.startswith('http'))
out = args[args.index('-o') + 1] if '-o' in args else None
q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))
with open(os.path.join(d, 'calls.log'), 'a') as f:
    f.write(json.dumps(q) + '\n')
state = json.load(open(os.path.join(d, 'state.json')))
act = q.get('action')
if act == 'dashboard':
    body = {'status': 'ok', 'venues': state['venues'], 'contacts': state['contacts']}
elif act == 'update_contact':
    body = {'status': 'error', 'message': 'Contact not found'}
    for c in state['contacts']:
        if c['contact_id'] == q.get('contact_id') and c['venue_id'] == q.get('venue_id') and q.get('field') == 'verified':
            c['verified'] = q.get('value')
            body = {'status': 'ok', 'contact_id': c['contact_id'], 'field': 'verified', 'value': q.get('value')}
    json.dump(state, open(os.path.join(d, 'state.json'), 'w'))
elif act == 'venue_detail':
    body = {'status': 'ok', 'venue': {'venue_id': q.get('venue_id')},
            'contacts': [c for c in state['contacts'] if c['venue_id'] == q.get('venue_id')]}
else:
    body = {'status': 'error', 'message': 'unexpected action ' + str(act)}
text = json.dumps(body)
if out:
    open(out, 'w').write(text)
else:
    sys.stdout.write(text)
'''

FAKE_GUARD = r'''#!/usr/bin/python3
import json, os, sys
d = os.environ['STUB_DIR']
cmd = sys.argv[1]
with open(os.path.join(d, 'guard.log'), 'a') as f:
    f.write(json.dumps({'argv': sys.argv[1:], 'ZB_MAX_PER_RUN': os.environ.get('ZB_MAX_PER_RUN'),
                        'ZB_UNKNOWN_CACHE_DAYS': os.environ.get('ZB_UNKNOWN_CACHE_DAYS')}) + '\n')
verdicts = json.load(open(os.path.join(d, 'verdicts.json')))
if cmd == 'lookup':
    emails = [l.strip() for l in sys.stdin if l.strip()]
    print(json.dumps({e: ({'status': verdicts[e]['status'], 'fresh': True} if verdicts.get(e, {}).get('cached') else None)
                      for e in emails}))
    sys.exit(0)
if cmd == 'budget':
    print(json.dumps({'allowed': True, 'reason': 'ok', 'run_used': 0, 'run_limit': 5, 'day_used': 0,
                      'day_limit': 10, 'credits_remaining': 999, 'reserve': 100}))
    sys.exit(0)
email = sys.argv[2]
v = verdicts.get(email, {'status': 'deferred', 'reason': 'run_budget_reached', 'charged': False})
print(json.dumps(dict({'email': email, 'cached': False}, **v)))
'''


class ReverifyTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix='reverify-')
        bindir = os.path.join(self.d, 'bin')
        os.makedirs(bindir)
        with open(os.path.join(bindir, 'curl'), 'w') as f:
            f.write(FAKE_CURL)
        with open(os.path.join(self.d, 'guard.py'), 'w') as f:
            f.write(FAKE_GUARD)
        os.chmod(os.path.join(bindir, 'curl'), 0o755)
        self.env = dict(os.environ, STUB_DIR=self.d, PATH=bindir + ':' + os.environ['PATH'],
                        ZB_GUARD=os.path.join(self.d, 'guard.py'), APPS_SCRIPT_URL='http://stub.invalid/exec')
        for k in ('ZB_MAX_PER_RUN', 'ZB_UNKNOWN_CACHE_DAYS', 'ZB_RUN_ID'):
            self.env.pop(k, None)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def state(self, contacts, verdicts):
        venues = [{'venue_id': 'V-1', 'status': 'pipelined'}, {'venue_id': 'V-2', 'status': 'pipelined'},
                  {'venue_id': 'V-9', 'status': 'contacted'}]
        json.dump({'venues': venues, 'contacts': contacts}, open(os.path.join(self.d, 'state.json'), 'w'))
        json.dump(verdicts, open(os.path.join(self.d, 'verdicts.json'), 'w'))

    def run_it(self, *args, env=None):
        return subprocess.run(['bash', REVERIFY, *args], capture_output=True, text=True, env=env or self.env)

    def calls(self, name='calls.log'):
        p = os.path.join(self.d, name)
        return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

    def contacts(self):
        return {c['contact_id']: c for c in json.load(open(os.path.join(self.d, 'state.json')))['contacts']}

    def test_updates_via_update_contact_and_reads_back(self):
        self.state([
            {'contact_id': 'C-1', 'venue_id': 'V-1', 'name': 'Jane Doe', 'email': 'jane.doe@venueone.com', 'verified': 'unknown'},
            {'contact_id': 'C-2', 'venue_id': 'V-1', 'name': 'Liz McQuay', 'email': 'events@venueone.com', 'verified': 'unknown'},
            {'contact_id': 'C-3', 'venue_id': 'V-1', 'name': 'Info', 'email': 'info@venueone.com', 'verified': 'unknown'},
            {'contact_id': 'C-4', 'venue_id': 'V-2', 'name': 'Bob Smith', 'email': 'bob.smith@venuetwo.com', 'verified': 'unknown'},
            {'contact_id': 'C-5', 'venue_id': 'V-2', 'name': 'No Reply', 'email': 'noreply@venuetwo.com', 'verified': 'unknown'},
            {'contact_id': 'C-6', 'venue_id': 'V-9', 'name': 'Sent Already', 'email': 'sent.already@x.com', 'verified': 'unknown'},
        ], {'jane.doe@venueone.com': {'status': 'invalid', 'reason': 'verified', 'charged': True},
            'bob.smith@venuetwo.com': {'status': 'valid', 'reason': 'verified', 'charged': True}})
        r = self.run_it()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        c = self.contacts()
        self.assertEqual(c['C-1']['verified'], 'invalid')
        self.assertEqual(c['C-2']['verified'], 'role')        # role mailbox with a real name, not paid for
        self.assertEqual(c['C-3']['verified'], 'unknown')     # role mailbox without a person: left alone
        self.assertEqual(c['C-4']['verified'], 'valid')
        self.assertEqual(c['C-5']['verified'], 'unknown')     # hard reject: skipped, not paid for
        self.assertEqual(c['C-6']['verified'], 'unknown')     # not a pipelined venue
        updates = [q for q in self.calls() if q.get('action') not in ('dashboard', 'venue_detail')]
        self.assertTrue(updates)
        self.assertTrue(all(q['action'] == 'update_contact' and q['field'] == 'verified' and q['venue_id']
                            for q in updates), updates)
        verified_emails = [g['argv'][1] for g in self.calls('guard.log') if g['argv'][0] == 'verify']
        self.assertEqual(sorted(verified_emails), ['bob.smith@venuetwo.com', 'jane.doe@venueone.com'])
        self.assertIn('Sheet updated (read back): 3', r.stdout)
        self.assertIn('Now valid: 1', r.stdout)

    def test_cap_is_not_raised_by_dotenv_and_no_retry_unknown(self):
        self.state([{'contact_id': 'C-1', 'venue_id': 'V-1', 'name': 'Jane Doe', 'email': 'jane.doe@venueone.com',
                     'verified': 'unknown'}], {'jane.doe@venueone.com': {'status': 'unknown', 'reason': 'cache_hit',
                                                                          'charged': False}})
        r = self.run_it()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for g in self.calls('guard.log'):
            if g['argv'][0] == 'lookup':
                continue                    # read-only cache lookup happens before the cap is set
            self.assertEqual(g['ZB_MAX_PER_RUN'], '5')
            self.assertEqual(g['ZB_UNKNOWN_CACHE_DAYS'], '30')
            self.assertNotIn('--retry-unknown', g['argv'])
        self.assertIn('Still unknown: 1', r.stdout)
        env = dict(self.env, ZB_MAX_PER_RUN='2')
        self.run_it(env=env)
        self.assertEqual(self.calls('guard.log')[-1]['ZB_MAX_PER_RUN'], '2')

    def test_deferral_stops_the_whole_run(self):
        self.state([
            {'contact_id': 'C-1', 'venue_id': 'V-1', 'name': 'Jane Doe', 'email': 'jane.doe@venueone.com', 'verified': 'unknown'},
            {'contact_id': 'C-4', 'venue_id': 'V-2', 'name': 'Bob Smith', 'email': 'bob.smith@venuetwo.com', 'verified': 'unknown'},
        ], {})
        r = self.run_it()
        self.assertIn('[STOP]', r.stdout)
        verified = [g for g in self.calls('guard.log') if g['argv'][0] == 'verify']
        self.assertEqual(len(verified), 1)

    def test_failed_update_is_reported(self):
        self.state([{'contact_id': 'C-1', 'venue_id': 'V-1', 'name': 'Jane Doe', 'email': 'jane.doe@venueone.com',
                     'verified': 'unknown'}], {'jane.doe@venueone.com': {'status': 'invalid', 'charged': True}})
        # make every update_contact call fail on the stub backend
        src = open(os.path.join(self.d, 'bin', 'curl')).read().replace("q.get('field') == 'verified'", 'False')
        open(os.path.join(self.d, 'bin', 'curl'), 'w').write(src)
        r = self.run_it()
        self.assertEqual(r.returncode, 1)
        self.assertIn('[API ERROR]', r.stdout)
        self.assertIn('Update failures: 1', r.stdout)

    def test_dry_run_pays_nothing(self):
        self.state([{'contact_id': 'C-1', 'venue_id': 'V-1', 'name': 'Jane Doe', 'email': 'jane.doe@venueone.com',
                     'verified': 'unknown'}], {'jane.doe@venueone.com': {'status': 'valid', 'charged': True}})
        r = self.run_it('--dry-run')
        self.assertEqual(r.returncode, 0)
        self.assertEqual([g for g in self.calls('guard.log') if g['argv'][0] == 'verify'], [])
        self.assertEqual([q for q in self.calls() if q['action'] == 'update_contact'], [])

    def test_unverified_mode_cached_first_dry_run_and_removal(self):
        self.state([
            {'contact_id': 'C-1', 'venue_id': 'V-9', 'name': 'Jane Doe', 'email': 'jane.doe@venueone.com', 'verified': 'unverified'},
            {'contact_id': 'C-2', 'venue_id': 'V-1', 'name': 'Bob Smith', 'email': 'bob.smith@venuetwo.com', 'verified': 'unverified'},
            {'contact_id': 'C-3', 'venue_id': 'V-1', 'name': 'Old Row', 'email': 'old.row@venuetwo.com', 'verified': 'deferred'},
            {'contact_id': 'C-4', 'venue_id': 'V-2', 'name': 'Sam Hash', 'email': 'a1b2c3d4e5f6a7b8c9d0@venuetwo.com', 'verified': 'unverified'},
            {'contact_id': 'C-5', 'venue_id': 'V-2', 'name': 'Ann Known', 'email': 'ann.known@venuetwo.com', 'verified': 'unknown'},
        ], {'jane.doe@venueone.com': {'status': 'invalid', 'reason': 'verified', 'charged': True},
            'bob.smith@venuetwo.com': {'status': 'valid', 'reason': 'cache_hit', 'charged': False, 'cached': True},
            'old.row@venuetwo.com': {'status': 'do_not_mail', 'reason': 'verified', 'charged': True}})
        r = self.run_it('--unverified', '--dry-run')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('would spend up to 2 ZeroBounce credit(s)', r.stdout)
        self.assertIn('cached valid (free)', r.stdout)
        self.assertEqual([g for g in self.calls('guard.log') if g['argv'][0] == 'verify'], [])
        r = self.run_it('--unverified')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        c = self.contacts()
        self.assertEqual(c['C-1']['verified'], 'invalid')     # any venue status in this mode
        self.assertEqual(c['C-2']['verified'], 'valid')
        self.assertEqual(c['C-3']['verified'], 'do_not_mail')
        self.assertEqual(c['C-4']['verified'], 'unverified')  # junk: not paid for, flagged
        self.assertEqual(c['C-5']['verified'], 'unknown')     # not in this mode
        verify = [g for g in self.calls('guard.log') if g['argv'][0] == 'verify']
        self.assertEqual(verify[0]['argv'][1], 'bob.smith@venuetwo.com')   # cached first
        self.assertEqual(verify[-1]['ZB_MAX_PER_RUN'], '2')                # cap = paid checks needed
        removal = r.stdout.split('FLAGGED FOR REMOVAL', 1)[1]
        for e in ('jane.doe@venueone.com', 'old.row@venuetwo.com', 'a1b2c3d4e5f6a7b8c9d0@venuetwo.com'):
            self.assertIn(e, removal)
        r = self.run_it('--unverified', '--limit', '1', '--dry-run')
        self.assertIn('cap this run: 1', r.stdout)

    def test_backend_handler_takes_these_params(self):
        gs = open(os.path.join(ROOT, 'apps_script.gs')).read()
        self.assertRegex(gs, r"['\"]update_contact['\"]\s*[:)]")
        body = gs[gs.index('function updateContact_('):]
        body = body[:body.index('\nfunction ', 10)]
        for p in ('contact_id', 'venue_id', 'field', 'value'):
            self.assertIn(f'params.{p}', body)
        self.assertRegex(body, r"'verified'\s*:\s*6")


if __name__ == '__main__':
    unittest.main(verbosity=2)
