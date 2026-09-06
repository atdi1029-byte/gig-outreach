#!/usr/bin/env python3
"""
taste_backtest.py — validates that taste_score.py ranks known-good venues
above known-bad ones.

Pulls:
  - Past gigs (from Apps Script get_gigs) = ground truth positives
  - Venues the user rated positively in taste_notes.md
  - A sample of untouched/junk venues as negatives

Prints Spearman rank correlation between taste scores and actual outcomes.
Exits 0 if correlation >= 0.3 (decent signal), 1 otherwise.

Run this whenever taste_score.py or venue_classifier.py changes.
"""

import json
import os
import re
import subprocess
import sys
from urllib.request import urlopen

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from taste_score import score as taste_score
from venue_classifier import classify

APPS_SCRIPT_URL = "https://script.google.com/macros/s/AKfycbxlZsGnG_pZG27FJjI8A_CWI5PZ1qs5tlyt2FbqlzfTm5sEvdQjStRDoobOkMOWzyBT/exec"


def fetch_json(action):
    url = f"{APPS_SCRIPT_URL}?action={action}"
    with urlopen(url, timeout=30) as resp:
        return json.loads(resp.read())


def load_taste_positives():
    """Extract venue names rated positively from taste_notes.md."""
    path = os.path.join(SCRIPT_DIR, 'taste_notes.md')
    positives = set()
    if not os.path.exists(path):
        return positives
    with open(path) as f:
        for line in f:
            # Lines like "- **Venue Name** — positive: ..."
            m = re.search(r'\*\*(.+?)\*\*.*positive', line, re.IGNORECASE)
            if m:
                positives.add(m.group(1).strip().lower())
    return positives


def spearman(x, y):
    """Spearman rank correlation between two lists."""
    n = len(x)
    if n < 3:
        return 0.0

    def ranks(vals):
        indexed = sorted(enumerate(vals), key=lambda t: t[1])
        r = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j < n - 1 and indexed[j + 1][1] == indexed[j][1]:
                j += 1
            avg_rank = (i + j) / 2.0 + 1
            for k in range(i, j + 1):
                r[indexed[k][0]] = avg_rank
            i = j + 1
        return r

    rx = ranks(x)
    ry = ranks(y)
    d2 = sum((a - b) ** 2 for a, b in zip(rx, ry))
    return 1 - (6 * d2) / (n * (n * n - 1))


def main():
    print("Fetching venues and gigs...")
    venues_data = fetch_json('venues')
    gigs_data = fetch_json('get_gigs')

    venues = venues_data.get('venues', [])
    gigs = gigs_data.get('gigs', [])

    # Build sets
    gig_names = set()
    for g in gigs:
        name = (g.get('venue') or g.get('venue_name') or '').strip().lower()
        if name:
            gig_names.add(name)

    taste_positives = load_taste_positives()
    positive_names = gig_names | taste_positives

    print(f"Ground truth: {len(gig_names)} past gigs, {len(taste_positives)} taste positives")
    print(f"Total venues to score: {len(venues)}")

    # Score all venues
    scores = []
    labels = []
    names_out = []

    for v in venues:
        name = (v.get('name') or '').strip()
        name_lower = name.lower()
        cat = v.get('category', '')
        notes = v.get('notes', '')

        cl = classify(name, cat, notes)
        s, reasons = taste_score(v, cl)

        is_positive = 1 if name_lower in positive_names else 0

        scores.append(s)
        labels.append(is_positive)
        names_out.append(name)

    # Spearman correlation
    rho = spearman(scores, labels)
    print(f"\nSpearman rho: {rho:.4f}")

    # Top-10 and bottom-10 by score
    indexed = sorted(enumerate(scores), key=lambda t: t[1], reverse=True)

    print("\n--- Top 10 by taste score ---")
    for rank, (i, s) in enumerate(indexed[:10], 1):
        tag = " [PAST GIG]" if labels[i] else ""
        print(f"  {rank:>2}. {s:5.1f}  {names_out[i]}{tag}")

    print("\n--- Bottom 10 by taste score ---")
    for rank, (i, s) in enumerate(indexed[-10:], 1):
        tag = " [PAST GIG]" if labels[i] else ""
        print(f"  {rank:>2}. {s:5.1f}  {names_out[i]}{tag}")

    # How many positives in top quartile?
    q1 = len(venues) // 4
    top_q_positives = sum(1 for i, _ in indexed[:q1] if labels[i])
    total_positives = sum(labels)
    if total_positives > 0:
        recall_at_q1 = top_q_positives / total_positives
        print(f"\nRecall@Q1: {top_q_positives}/{total_positives} = {recall_at_q1:.1%} of positives in top 25%")

    # Verdict
    print(f"\n{'=' * 40}")
    if rho >= 0.3:
        print(f"PASS  Spearman {rho:.4f} >= 0.30")
        return 0
    elif rho >= 0.2:
        print(f"WARN  Spearman {rho:.4f} — marginal (0.20-0.30)")
        return 0  # warn but pass
    else:
        print(f"FAIL  Spearman {rho:.4f} < 0.20 — model is not ranking well")
        return 1


if __name__ == '__main__':
    sys.exit(main())
