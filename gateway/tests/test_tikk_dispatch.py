"""Tests for gateway/tikk-dispatch: the verb allowlist is the security boundary."""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DISPATCH = os.path.join(os.path.dirname(HERE), "tikk-dispatch")


def run(cmd, home):
    """Run the dispatcher with a fake tikk-reminders that prints its argv, in an isolated HOME."""
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "SSH_ORIGINAL_COMMAND": cmd, "SSH_CLIENT": "203.0.113.5 1 22"}
    return subprocess.run([sys.executable, os.path.join(home, "bin", "tikk-dispatch")], env=env,
                          capture_output=True, text=True, timeout=20)


class Dispatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(bindir)
        with open(DISPATCH, "rb") as src, open(os.path.join(bindir, "tikk-dispatch"), "wb") as dst:
            dst.write(src.read())
        with open(os.path.join(bindir, "tikk-reminders"), "w") as f:
            f.write("import sys, os, json\nprint(json.dumps({'argv': sys.argv[1:], 'path': os.environ.get('PATH')}))\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_ping(self):
        p = run("ping", self.tmp.name)
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "pong"))

    def test_verb_passes_through_with_fixed_path(self):
        p = run("show 'My List' --json", self.tmp.name)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = eval(p.stdout)  # our fake prints a dict literal
        self.assertEqual(out["argv"], ["show", "My List", "--json"])
        self.assertEqual(out["path"], "/usr/bin:/bin:/usr/sbin:/sbin")

    def test_json_may_lead(self):
        p = run("--json lists", self.tmp.name)
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_refusals_exit_64_and_are_audited(self):
        for cmd in ("", "true", "../../bin/sh", "show; id", "-- lists", "'"):
            p = run(cmd, self.tmp.name)
            self.assertEqual(p.returncode, 64, cmd)
            self.assertIn("tikk-dispatch:", p.stderr)
        with open(os.path.join(self.tmp.name, ".tikk", "audit.log"), encoding="utf-8") as f:
            log = f.read()
        self.assertIn("event=refused", log)
        self.assertIn("client=203.0.113.5", log)
        self.assertEqual(oct(os.stat(os.path.join(self.tmp.name, ".tikk", "audit.log")).st_mode & 0o777), "0o600")

    def test_dash_names_reach_the_tool_intact(self):
        p = run("add Groceries -- '-dash first'", self.tmp.name)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(eval(p.stdout)["argv"], ["add", "Groceries", "--", "-dash first"])


if __name__ == "__main__":
    unittest.main()
