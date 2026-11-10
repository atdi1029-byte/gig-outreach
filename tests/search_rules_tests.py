#!/usr/bin/env python3
"""Offline tests for the Google and LinkedIn search steps.

Alex, Nov 8 2026: the wine bar "Altitude" (Arlington VA) was searched as "Altitude"
Arlington; the run saved and opened the Facebook page of Altitude Trampoline Park,
Arlington, Texas, and LinkedIn's three pages were other companies called Altitude.

Covers outreach_rules (the search text, "is this place in DC/MD/VA"), and the REAL
LinkedIn result filter and Facebook/Instagram picker, run straight out of pipeline.sh's
heredocs with made-up result pages. Nothing touches Chrome, the sheet or the network.

    /usr/bin/python3 tests/search_rules_tests.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import outreach_rules as R  # noqa: E402

PIPELINE = open(os.path.join(ROOT, 'pipeline.sh'), encoding='utf-8').read()
POSTCHECK = open(os.path.join(ROOT, 'postcheck.sh'), encoding='utf-8').read()
US = '\x1f'


def heredoc(src, marker):
    """The python heredoc that follows `marker` in a shell script."""
    i = src.index(marker)
    start = src.index("<<'PYEOF'\n", i) + len("<<'PYEOF'\n")
    return src[start:src.index('\nPYEOF\n', start)]


def run_py(code, argv=(), env=None):
    e = dict(os.environ, SCRIPT_DIR=ROOT)
    e.update(env or {})
    p = subprocess.run(['/usr/bin/python3', '-', *argv], input=code, capture_output=True, text=True, env=e)
    if p.returncode != 0:
        raise AssertionError(p.stderr[-2000:])
    return [line.split(US) for line in p.stdout.splitlines() if line]


def li_filter(venue, city, state, people):
    rows = run_py(heredoc(PIPELINE, '_rb_py "$venue_id linkedin-filter" python3 -'), env={
        'LI_PAGE_JSON': json.dumps({'ok': True, 'people': people}), 'KNAMES': '',
        'RB_VENUE_NAME': venue, 'RB_CITY': city, 'RB_STATE': state})
    return {r[1] if r[0] == 'REJ' else r[2]: (r[0], r[3] if r[0] == 'REJ' else '') for r in rows}


def pick(kind, venue, city, state, category, urls, texts=None):
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump({'status': 'ok', 'venue': {'city': city, 'state': state, 'category': category}}, f)
    try:
        rows = run_py(heredoc(PIPELINE, '_rb_py "$venue_id pick-$kind" python3 -'),
                      argv=[kind, venue, f.name, json.dumps(urls)],
                      env={'RB_RESULT_TEXT': json.dumps(texts or {}), 'RB_CANDIDATE_LOG': '', 'RB_VENUE_DOMAIN': ''})
    finally:
        os.unlink(f.name)
    best = next((r[1] for r in rows if r[0] == 'BEST'), '')
    return best, {r[1]: r[2] for r in rows if r[0] == 'REJECT'}


class SearchText(unittest.TestCase):
    def test_google_query_always_has_state_and_type(self):
        self.assertEqual(R.google_query('Altitude', 'contact', 'Arlington', 'VA', 'wine_bar'),
                         '"Altitude" wine bar Arlington VA contact')
        self.assertEqual(R.google_query('Altitude', 'facebook', 'Arlington', 'va', 'wine_bar'),
                         '"Altitude" wine bar Arlington VA facebook')

    def test_type_not_repeated_or_invented(self):
        self.assertEqual(R.google_query('Gvino Wine Bar', 'instagram', 'Baltimore', 'MD', 'wine_bar'),
                         '"Gvino Wine Bar" Baltimore MD instagram')
        self.assertEqual(R.google_query('Tudor Place', 'contact', 'Washington', 'DC', 'other'),
                         '"Tudor Place" Washington DC contact')
        self.assertEqual(R.google_query('Tudor Place', 'contact'), '"Tudor Place" contact')

    def test_cli_reads_the_venue_detail_file(self):
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
            json.dump({'status': 'ok', 'venue': {'city': 'Arlington', 'state': 'VA', 'category': 'wine_bar'}}, f)
        try:
            out = subprocess.run(['/usr/bin/python3', os.path.join(ROOT, 'outreach_rules.py'), 'search-query', 'google',
                                  '--name', 'Altitude', '--tail', 'contact', '--detail', f.name],
                                 capture_output=True, text=True).stdout.strip()
        finally:
            os.unlink(f.name)
        self.assertEqual(out, '"Altitude" wine bar Arlington VA contact')

    def test_linkedin_query_is_the_exact_name_in_quotes(self):
        self.assertEqual(R.linkedin_query('The Ivy Hotel', 'Baltimore', 'MD'), '"The Ivy Hotel"')
        self.assertEqual(R.linkedin_query('Altitude', 'Arlington', 'VA'), '"Altitude" Arlington')
        self.assertEqual(R.linkedin_query('The Ivy', 'Baltimore', 'MD'), '"The Ivy" Baltimore')

    def test_no_google_query_is_built_by_hand_any_more(self):
        # every Google search of the pipeline goes through _rb_google_query
        for line in PIPELINE.splitlines():
            if re.search(r'_rb_(social|snippet)_search |runner_google_(nav|candidates) ', line) and '()' not in line \
                    and not line.lstrip().startswith('#'):
                self.assertNotIn('\\"$venue\\"', line, line)
                self.assertNotIn('"$venue$', line, line)
        self.assertIn('R.linkedin_query(', heredoc(POSTCHECK, 'run_py li-quote python3 - "$SCRIPT_DIR"'))
        self.assertIn('R.linkedin_location_in_area(', heredoc(POSTCHECK, 'run_py li-filter python3 -'))


class Area(unittest.TestCase):
    def test_linkedin_locations(self):
        yes = ['Arlington, Virginia, United States', 'Washington DC-Baltimore Area', 'Baltimore, Maryland, United States',
               'Washington, District of Columbia, United States', 'Greater Richmond Region', 'Annapolis, MD']
        no = ['Arlington, Texas, United States', 'Serbia', 'Seattle, Washington, United States',
              'Charleston, West Virginia, United States', 'Dallas-Fort Worth Metroplex', 'London, England, United Kingdom',
              'Virginia, Minnesota, United States']
        for s in yes:
            self.assertIs(R.linkedin_location_in_area(s), True, s)
        for s in no:
            self.assertIs(R.linkedin_location_in_area(s), False, s)
        for s in ['', 'United States', 'Current: General Manager at Altitude', 'Connect']:
            self.assertIsNone(R.linkedin_location_in_area(s), s)

    def test_a_pennsylvania_sweep_find_keeps_its_own_state(self):
        self.assertIs(R.linkedin_location_in_area('Lancaster, Pennsylvania, United States', 'PA'), True)
        self.assertIs(R.linkedin_location_in_area('Lancaster, Pennsylvania, United States', 'MD'), False)

    def test_result_text(self):
        self.assertEqual(R.place_outside_area('Altitude Trampoline Park Arlington - Facebook. Arlington, TX. 5,120 likes'), 'TX')
        self.assertEqual(R.place_outside_area('Altitude Trampoline Park in Arlington, Texas'), 'Texas')
        self.assertEqual(R.place_outside_area('Altitude Wine Bar | Arlington, VA'), '')
        self.assertEqual(R.place_outside_area('Altitude - Home | Facebook'), '')
        self.assertEqual(R.place_outside_area('From Texas to Crystal City, Virginia: a new wine bar'), '')


ALTITUDE_PAGE = [
    # the Nov 8 run's results for the wine bar "Altitude", Arlington VA
    {'name': 'Tamara Bullock', 'title': 'Founder & Managing Director at Altitude | Aviation & Sustainability | U.S & EMEA',
     'location': 'Serbia', 'current': '', 'past': ''},
    {'name': 'Dana Whitfield', 'title': 'General Manager at Altitude Trampoline Park',
     'location': 'Arlington, Texas, United States', 'current': 'General Manager at Altitude Trampoline Park', 'past': ''},
    {'name': 'Marco Ruiz', 'title': 'Senior Art Director at Altitude Sports & Entertainment',
     'location': 'Denver, Colorado, United States', 'current': '', 'past': ''},
    {'name': 'Priya Shah', 'title': 'Hospitality leader', 'location': 'Arlington, Virginia, United States',
     'current': 'General Manager at Altitude', 'past': ''},
    {'name': 'Owen Clarke', 'title': 'Sommelier at Altitude Wine Bar', 'location': 'Washington DC-Baltimore Area',
     'current': '', 'past': ''},
    {'name': 'Lena Fox', 'title': 'Principal at Altitude', 'location': '', 'current': '', 'past': ''},
]


class LinkedInFilter(unittest.TestCase):
    def test_one_word_name_keeps_only_this_venue_in_the_area(self):
        got = li_filter('Altitude', 'Arlington', 'VA', ALTITUDE_PAGE)
        self.assertEqual(got['Priya Shah'][0], 'OK')
        self.assertEqual(got['Owen Clarke'][0], 'OK')
        self.assertEqual(got['Tamara Bullock'][0], 'REJ')
        self.assertIn('not DC/MD/VA', got['Tamara Bullock'][1])
        self.assertEqual(got['Dana Whitfield'][0], 'REJ')        # another company with the word in its name
        self.assertEqual(got['Marco Ruiz'][0], 'REJ')
        self.assertEqual(got['Lena Fox'][0], 'REJ')              # no location + a one-word name
        self.assertIn('unknown', got['Lena Fox'][1])

    def test_full_name_still_matches_as_a_phrase(self):
        people = [
            {'name': 'Ana Reyes', 'title': 'Director of Events at The Ivy Hotel', 'location': 'Baltimore, Maryland, United States',
             'current': '', 'past': ''},
            {'name': 'Tom Hale', 'title': 'Director of Events at The Ivy Hotel', 'location': 'Dallas, Texas, United States',
             'current': '', 'past': ''},
            {'name': 'Kim Park', 'title': 'Events at The Ivy Hotel', 'location': '', 'current': '', 'past': ''},
            {'name': 'Joe Dunn', 'title': 'Partner at Ivy Hospitality', 'location': 'Baltimore, Maryland, United States',
             'current': '', 'past': ''},
        ]
        got = li_filter('The Ivy Hotel', 'Baltimore', 'MD', people)
        self.assertEqual(got['Ana Reyes'][0], 'OK')
        self.assertEqual(got['Tom Hale'][0], 'REJ')
        self.assertEqual(got['Kim Park'][0], 'OK')               # no location on the card: the full name is enough
        self.assertEqual(got['Joe Dunn'][0], 'REJ')


class SocialPicker(unittest.TestCase):
    URLS = ['https://www.facebook.com/p/Altitude-Wine-Bar-61587332106320/', 'https://www.facebook.com/altitudefortworth/',
            'https://www.facebook.com/altitudearlington/']

    def test_new_style_page_is_a_venue_page(self):
        best, rej = pick('facebook', 'Altitude', 'Arlington', 'VA', 'wine_bar', self.URLS)
        self.assertEqual(best, 'https://www.facebook.com/p/Altitude-Wine-Bar-61587332106320/')
        self.assertIn('https://www.facebook.com/altitudefortworth/', rej)

    def test_new_style_page_wins_whatever_the_order(self):
        best, _ = pick('facebook', 'Altitude', 'Arlington', 'VA', 'wine_bar', list(reversed(self.URLS)))
        self.assertEqual(best, 'https://www.facebook.com/p/Altitude-Wine-Bar-61587332106320/')

    def test_a_result_placed_in_another_state_is_dropped(self):
        texts = {'https://www.facebook.com/altitudearlington/': 'Altitude Trampoline Park Arlington - Facebook Arlington, TX. 5,120 likes'}
        best, rej = pick('facebook', 'Altitude', 'Arlington', 'VA', 'wine_bar', ['https://www.facebook.com/altitudearlington/'], texts)
        self.assertEqual(best, '')
        self.assertIn('TX', rej['https://www.facebook.com/altitudearlington/'])

    def test_without_result_text_nothing_changes(self):
        best, _ = pick('facebook', 'Gvino Wine Bar', 'Baltimore', 'MD', 'wine_bar', ['https://www.facebook.com/gvinobaltimore/'])
        self.assertEqual(best, 'https://www.facebook.com/gvinobaltimore/')
        best, _ = pick('instagram', 'Gvino Wine Bar', 'Baltimore', 'MD', 'wine_bar', ['https://www.instagram.com/gvino_baltimore/'],
                       {'https://www.instagram.com/gvino_baltimore/': 'Gvino (@gvino_baltimore) Baltimore, MD wine bar'})
        self.assertEqual(best, 'https://www.instagram.com/gvino_baltimore/')

    def test_other_people_pages_stay_out(self):
        best, rej = pick('facebook', 'Altitude', 'Arlington', 'VA', 'wine_bar',
                         ['https://www.facebook.com/p/Madison-Niles-100012345678/', 'https://www.facebook.com/people/Some-One/100012345678/'])
        self.assertEqual(best, '')
        self.assertEqual(len(rej), 2)


class Names(unittest.TestCase):
    def test_page_labels_are_not_people(self):
        self.assertEqual(R.clean_person_name('El Patio Rewards Program'), '')
        self.assertEqual(R.clean_person_name('Template Placeholder'), '')
        self.assertEqual(R.clean_person_name('Arlene Stecher'), 'Arlene Stecher')
        self.assertEqual(R.clean_person_name('Crystal Drive'), '')       # the street beside hello@
        self.assertEqual(R.clean_person_name('Minnie Driver'), 'Minnie Driver')

    def test_template_address_is_junk(self):
        self.assertEqual(R.check_email('template.placeholder@gmail.com', 'hartgeyard.com', 'Hartge Yacht Yard',
                                       found_on_venue_site=True, venue_mailto=True)['action'], 'reject')
        self.assertEqual(R.junk_reason('jane.template@venue.com'), 'placeholder')
        self.assertEqual(R.junk_reason('jane@venue.com'), '')

    def test_no_name_from_a_venue_word(self):
        self.assertEqual(R.name_from_email('arlene.cork@gmail.com', 'County Cork Wine Pub'), '')
        self.assertEqual(R.check_email('arlene.cork@gmail.com', 'thecorkpub.com', 'County Cork Wine Pub',
                                       found_on_venue_site=True, venue_mailto=True)['name_hint'], '')
        self.assertEqual(R.name_from_email('jane.doe@gmail.com', 'County Cork Wine Pub'), 'Jane Doe')
        self.assertEqual(R.name_from_email('jim.hartge@hartgeyard.com', 'Hartge Yacht Yard'), 'Jim Hartge')
        self.assertEqual(R.name_from_email('jane.doe@x.com'), 'Jane Doe')


class Forms(unittest.TestCase):
    def test_reservation_link_is_not_a_form_and_dexter_is(self):
        import site_discovery as SD
        res = '<a href="https://www.sevenrooms.com/explore/altitude/reservations/create/search/?date=2026-06-11">Reserve</a>'
        self.assertEqual(SD.detect_contact_forms(res, 'https://www.altitude-va.com/visit'), [])
        dex = ('<script src="https://app.teamdexter.com/iframe-position-tracker.js"></script>'
               '<iframe id="dexterIframe" src="https://app.teamdexter.com/embed-applications/6a33b3d54db647d5b4843cb9"></iframe>')
        got = SD.detect_contact_forms(dex, 'https://www.altitude-va.com/inquiry-form')
        self.assertTrue(got and all(f['kind'] == 'dexter' for f in got), got)
        self.assertIn('https://www.altitude-va.com/inquiry-form', [f['url'] for f in got])


if __name__ == '__main__':
    unittest.main(verbosity=1)
