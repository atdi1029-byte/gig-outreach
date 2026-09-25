#!/usr/bin/env python3
"""Proves tests/check_heredocs.py catches broken embedded python (the Aug/Sep
Apollo IndentationError that `bash -n` could not see) and passes good code.

    /usr/bin/python3 tests/check_heredocs_tests.py
"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, 'check_heredocs.py')

GOOD = '''#!/bin/bash
NAME="x"
OUT=$(python3 - "$NAME" <<'PYEOF'
import sys
for a in sys.argv[1:]:
    print(a)
PYEOF
)
python3 << EOF
data = "$NAME"
if data:
    print(data)
EOF
python3 -c "import json; print(json.dumps({'a': '$NAME'}))"
'''

# the shape of the real bug: a line under-indented inside an unquoted heredoc
BAD_HEREDOC = '''#!/bin/bash
RESULT=$(python3 << PYEOF
seen = set()
for a in [1, 2]:
    if a not in seen:
    seen.add(a)
print(len(seen))
PYEOF
)
'''

BAD_DASH_C = '''#!/bin/bash
python3 -c "
def rank(r):
    """doc"""
    return 1
"
'''


class CheckHeredocsTests(unittest.TestCase):
    def run_on(self, text):
        with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False) as f:
            f.write(text)
        try:
            return subprocess.run([sys.executable, CHECKER, f.name], capture_output=True, text=True)
        finally:
            os.unlink(f.name)

    def test_good_script_passes(self):
        r = self.run_on(GOOD)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn('3 embedded python blocks', r.stdout)

    def test_indentation_error_in_heredoc_fails(self):
        r = self.run_on(BAD_HEREDOC)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn('expected an indented block', r.stdout)

    def test_docstring_inside_dash_c_fails(self):
        # bash ends the "..." string at the first quote of a """docstring"""
        r = self.run_on(BAD_DASH_C)
        self.assertEqual(r.returncode, 1, r.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
