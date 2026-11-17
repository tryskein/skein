"""Runs the product e2e harness (scripts/e2e-test.sh) as one progon test.

The harness is a shell script, and progon has no adapter for plain scripts, so
the python adapter runs this file. The harness itself fails when no Playwright
test executed, so a green here means at least one e2e test ran.

The harness output is kept and printed after the unittest result line:
progon reads that line, and interleaved output would hide the verdict.
"""
import subprocess
import sys
import unittest

OUTPUT = []


class E2EHarness(unittest.TestCase):
    def test_e2e_harness(self):
        result = subprocess.run(
            ["bash", "scripts/e2e-test.sh"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        OUTPUT.append(result.stdout)
        self.assertEqual(result.returncode, 0, "scripts/e2e-test.sh failed")


if __name__ == "__main__":
    outcome = unittest.main(exit=False)
    sys.stdout.write("".join(OUTPUT))
    sys.exit(0 if outcome.result.wasSuccessful() else 1)
