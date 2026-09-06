"""Unit tests for gateway/tikk-reminders. Standard library only: `python3 -m unittest discover gateway/tests`."""
import importlib.machinery
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "tikk-reminders")


def load():
    loader = importlib.machinery.SourceFileLoader("tikk_reminders", SCRIPT)
    spec = importlib.util.spec_from_loader("tikk_reminders", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


T = load()


def ns(**kw):
    return type("A", (), kw)()


class Dates(unittest.TestCase):
    def test_utc_to_local_and_allday(self):
        iso, allday = T.local_iso("2026-09-11T22:00:00Z")
        self.assertRegex(iso, r"^2026-09-1\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$")
        self.assertIsInstance(allday, bool)

    def test_fractional_and_offset(self):
        iso, _ = T.local_iso("2026-09-10T16:00:00.123+00:00")
        self.assertTrue(iso.startswith("2026-09-10T"))

    def test_garbage_is_none_not_error(self):
        self.assertEqual(T.local_iso("not a date"), (None, False))
        self.assertEqual(T.local_iso(None), (None, False))

    def test_parse_due(self):
        self.assertEqual(T.parse_due("2026-09-10"), "2026-09-10")
        self.assertEqual(T.parse_due("2026-09-10T18:00"), "2026-09-10 18:00")
        with self.assertRaises(T.ToolError) as cm:
            T.parse_due("12/9")
        self.assertEqual(cm.exception.code, T.EX_USAGE)


class Normalize(unittest.TestCase):
    def test_shape(self):
        r = T.normalize({"externalId": "ABC", "title": "Milk", "notes": "", "priority": 1, "isCompleted": False, "list": "G"})
        self.assertEqual(r, {"id": "ABC", "name": "Milk", "body": None, "due": None, "allday": False,
                             "priority": 1, "completed": False, "completed_at": None, "list": "G"})

    def test_missing_fields_is_clean_error(self):
        with self.assertRaises(T.ToolError) as cm:
            T.normalize({"title": "x"})
        self.assertEqual(cm.exception.code, T.EX_UNAVAILABLE)


class StoreMeta(unittest.TestCase):
    def test_plist_color(self):
        blob = plistlib.dumps({"$objects": ["$null", {"red": 1.0, "green": 0.553, "blue": 0.157, "alpha": 1.0}]}, fmt=plistlib.FMT_BINARY)
        self.assertEqual(T.plist_color(blob), "#ff8d28")
        self.assertIsNone(T.plist_color(b"not a plist"))

    def test_emblem(self):
        self.assertEqual(T.emblem_of('{"Emoji" : "💪"}'), "💪")
        self.assertEqual(T.emblem_of("shopping1"), "shopping1")
        self.assertIsNone(T.emblem_of(None))

    def test_store_meta_from_sqlite(self):
        with tempfile.TemporaryDirectory() as d:
            import sqlite3
            p = os.path.join(d, "Data-x.sqlite")
            con = sqlite3.connect(p)
            con.execute("create table ZREMCDBASELIST (Z_PK int, ZISGROUP int, ZNAME text, ZPARENTLIST int, ZDADISPLAYORDER int, ZBADGEEMBLEM text, ZSHARINGSTATUS int, ZCOLOR blob, ZMARKEDFORDELETION int, ZSECTIONIDSORDERINGASDATA blob, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA blob, ZREMINDERIDSMERGEABLEORDERING_V2_JSON blob)")
            con.execute("create table ZREMCDBASESECTION (Z_PK int, ZLIST int, ZIDENTIFIER blob, ZDISPLAYNAME text, ZMARKEDFORDELETION int)")
            import uuid
            sec_a, sec_b = uuid.uuid4(), uuid.uuid4()
            rid = "AAAAAAAA-0000-0000-0000-000000000001"
            con.executemany("insert into ZREMCDBASELIST values (?,?,?,?,?,?,?,?,?,?,?,?)", [
                (1, 1, "Home", None, 0, None, 0, None, 0, None, None, None),
                (2, 0, "Groceries", 1, 0, "shopping1", 1, None, 0,
                 json.dumps({"orderedIdentifiers": [str(sec_b), str(sec_a)]}).encode(),
                 json.dumps({"memberships": [{"memberID": rid.lower(), "groupID": str(sec_a)}]}).encode(),
                 json.dumps(["other", rid]).encode()),
                (3, 0, "Errands", None, 1, None, 0, None, 0, None, None, None),
                (4, 0, "Deleted", None, 2, None, 0, None, 1, None, None, None),
            ])
            con.executemany("insert into ZREMCDBASESECTION values (?,?,?,?,?)", [
                (1, 2, sec_a.bytes, "Produce", 0),
                (2, 2, sec_b.bytes, "Bakery", 0),
                (3, 2, uuid.uuid4().bytes, "Gone", 1),
            ])
            con.commit(); con.close()
            meta = T.store_meta([p])
        self.assertEqual([g["name"] for g in meta["groups"]], ["Home"])
        self.assertEqual(meta["lists"]["Groceries"]["group"], "Home")
        self.assertTrue(meta["lists"]["Groceries"]["shared"])
        self.assertIsNone(meta["lists"]["Errands"]["group"])
        self.assertNotIn("Deleted", meta["lists"])
        # sections: display order from the list blob, membership by reminder id, manual position
        self.assertEqual(meta["lists"]["Groceries"]["sections"], ["Bakery", "Produce"])
        self.assertEqual(meta["lists"]["Errands"]["sections"], [])
        recs = T.decorate([{"id": rid, "list": "Groceries"}, {"id": "BBBBBBBB-0000-0000-0000-000000000002", "list": "Groceries"}], meta)
        self.assertEqual((recs[0]["section"], recs[0]["position"]), ("Produce", 1))
        self.assertEqual((recs[1]["section"], recs[1]["position"]), (None, None))

    def test_missing_store_is_empty(self):
        self.assertEqual(T.store_meta(["/nonexistent/Data-x.sqlite"]), {"lists": {}, "groups": []})


class Backend(unittest.TestCase):
    def test_argv_shape_options_then_separator_then_positionals(self):
        calls = []

        def fake_run(cmd, **kw):
            calls.append((cmd, kw))
            return subprocess.CompletedProcess(cmd, 0, stdout="[]", stderr="")
        with mock.patch.object(T, "find_tool", return_value="/x/reminders"), mock.patch.object(T.subprocess, "run", fake_run):
            T.rem_json("show", ["--only-completed"], ["--format"])
        cmd, kw = calls[0]
        self.assertEqual(cmd, ["/x/reminders", "show", "--only-completed", "--format=json", "--", "--format"])
        self.assertIs(kw["stdin"], subprocess.DEVNULL)
        self.assertEqual(kw["encoding"], "utf-8")

    def test_error_mapping(self):
        def failing(stderr):
            return lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, stdout="", stderr=stderr)
        with mock.patch.object(T, "find_tool", return_value="/x/reminders"):
            for msg, code in (("you need to grant reminders access", T.EX_NOPERM),
                              ("No reminders list matching Foo", T.EX_NOINPUT),
                              ("No reminder at index 3 on Foo", T.EX_NOINPUT),
                              ("something else", T.EX_UNAVAILABLE)):
                with mock.patch.object(T.subprocess, "run", failing(msg)):
                    with self.assertRaises(T.ToolError) as cm:
                        T.rem("show", (), ["Foo"])
                    self.assertEqual(cm.exception.code, code, msg)

    def test_missing_tool(self):
        with mock.patch.object(T, "CANDIDATES", ["/nonexistent/reminders"]):
            with self.assertRaises(T.ToolError) as cm:
                T.find_tool()
            self.assertEqual(cm.exception.code, T.EX_CONFIG)


class Resolve(unittest.TestCase):
    RECORDS = [
        {"id": "AAAAAAAA-0000-0000-0000-000000000001", "name": "Milk", "completed": False},
        {"id": "AAAAAAAA-0000-0000-0000-000000000002", "name": "Eggs", "completed": False},
        {"id": "AAAAAAAA-0000-0000-0000-000000000003", "name": "Eggs", "completed": False},
    ]

    def setUp(self):
        self.p = mock.patch.object(T, "fetch", return_value=list(self.RECORDS)); self.p.start()

    def tearDown(self):
        self.p.stop()

    def test_by_name(self):
        self.assertEqual(T.resolve("G", "Milk", "open")["id"], self.RECORDS[0]["id"])

    def test_by_id_with_and_without_prefix_case_insensitive(self):
        self.assertEqual(T.resolve("G", "x-apple-reminder://aaaaaaaa-0000-0000-0000-000000000001", "open")["name"], "Milk")
        self.assertEqual(T.resolve("G", "AAAAAAAA-0000-0000-0000-000000000001", "open")["name"], "Milk")

    def test_ambiguous_and_missing(self):
        with self.assertRaises(T.ToolError) as cm:
            T.resolve("G", "Eggs", "open")
        self.assertEqual(cm.exception.code, T.EX_DATAERR)
        with self.assertRaises(T.ToolError) as cm:
            T.resolve("G", "Bread", "open")
        self.assertEqual(cm.exception.code, T.EX_NOINPUT)


class ConfigAndAudit(unittest.TestCase):
    def test_config_parsing(self):
        with tempfile.NamedTemporaryFile("w", suffix=".cfg", delete=False) as f:
            f.write("# comment\nallow_lists = Groceries , Household  # trailing\naudit_log = off\nunknown = 1\n")
        try:
            cfg = T.read_config(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(cfg["allow_lists"], ["Groceries", "Household"])
        self.assertIsNone(cfg["audit_log"])
        self.assertTrue(T.allowed(cfg, "Groceries"))
        self.assertFalse(T.allowed(cfg, "Work"))
        with self.assertRaises(T.ToolError) as cm:
            T.require_allowed(cfg, "Work")
        self.assertEqual(cm.exception.code, T.EX_NOPERM)

    def test_missing_config_means_open_and_audit_on(self):
        cfg = T.read_config("/nonexistent/config")
        self.assertIsNone(cfg["allow_lists"])
        self.assertIsNone(cfg["allow_verbs"])
        self.assertEqual(cfg["audit_log"], T.DEFAULT_AUDIT)

    def test_allow_verbs(self):
        with tempfile.NamedTemporaryFile("w", suffix=".cfg", delete=False) as f:
            f.write("allow_verbs = lists, show, snapshot, add, complete, uncomplete\n")
        try:
            cfg = T.read_config(f.name)
        finally:
            os.unlink(f.name)
        self.assertTrue(T.verb_allowed(cfg, "complete"))
        self.assertFalse(T.verb_allowed(cfg, "delete"))
        self.assertTrue(T.verb_allowed(cfg, "check"))
        with mock.patch.object(T, "read_config", return_value=cfg):
            self.assertEqual(T.main(["delete", "G", "x"]), T.EX_NOPERM)

    def test_audit_line_and_mode(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "sub", "audit.log")
            with mock.patch.dict(os.environ, {"SSH_CLIENT": "203.0.113.5 50000 22"}):
                T.audit({"audit_log": path}, "delete", list="G", id="X", name='say "hi"', skipped=None)
            with open(path, encoding="utf-8") as f:
                line = f.read().strip()
            self.assertIn("client=203.0.113.5 event=delete", line)
            self.assertIn('name="say \\"hi\\""', line)
            self.assertNotIn("skipped", line)
            self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")

    def test_audit_off_writes_nothing(self):
        T.audit({"audit_log": None}, "delete")   # must not raise


class Verbs(unittest.TestCase):
    def test_snapshot_filters_by_allowlist(self):
        cfg = {"allow_lists": ["Groceries"], "audit_log": None}
        with mock.patch.object(T, "list_names", return_value=["Groceries", "Work"]), \
             mock.patch.object(T, "rem_json", return_value=[
                 {"externalId": "1", "title": "Milk", "list": "Groceries"},
                 {"externalId": "2", "title": "Plan", "list": "Work"}]), \
             mock.patch.object(T, "safe_meta", return_value={"lists": {"Groceries": {"group": "Home"}, "Work": {"group": "Office"}},
                                                               "groups": [{"name": "Home", "order": 0}, {"name": "Office", "order": 1}]}):
            snap, _ = T.verb_snapshot(ns(), cfg)
        self.assertEqual([l["name"] for l in snap["lists"]], ["Groceries"])
        self.assertEqual([g["name"] for g in snap["groups"]], ["Home"])
        self.assertEqual([r["name"] for r in snap["reminders"]], ["Milk"])

    def test_delete_of_completed_restores_on_failure(self):
        calls = []

        def fake_rem(sub, options=(), positionals=()):
            calls.append(sub)
            if sub == "delete":
                raise T.ToolError(T.EX_UNAVAILABLE, "boom")
            return ""
        rec = {"id": "AAAAAAAA-0000-0000-0000-000000000001", "name": "Old", "completed": True}
        with mock.patch.object(T, "resolve", return_value=rec), mock.patch.object(T, "rem", fake_rem):
            with self.assertRaises(T.ToolError):
                T.verb_mutate(ns(verb="delete", list="G", key="Old", mode="all"), {"audit_log": None, "allow_lists": None})
        self.assertEqual(calls, ["uncomplete", "delete", "complete"])

    def test_main_exit_codes(self):
        with mock.patch.object(T, "read_config", return_value={"allow_lists": ["G"], "audit_log": None}):
            self.assertEqual(T.main(["show", "Other"]), T.EX_NOPERM)
            with self.assertRaises(SystemExit) as cm:
                T.main(["add"])            # usage error → 64, not argparse's 2
            self.assertEqual(cm.exception.code, T.EX_USAGE)


if __name__ == "__main__":
    unittest.main()
