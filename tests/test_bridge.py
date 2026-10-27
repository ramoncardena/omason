"""Integration checks use real Unison and disposable replicas, never user data."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("omason", str(ROOT / "bin/omason"))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


@unittest.skipUnless(shutil.which("unison"), "requires Unison")
class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omason-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.left, self.right = self.root / "left replica", self.root / "right replica"
        self.config, self.state_dir = self.root / "profiles", self.root / "state"
        for path in (self.left, self.right, self.config):
            path.mkdir()
        self.env = patch.dict(os.environ, {"UNISON": str(self.config), "XDG_STATE_HOME": str(self.state_dir)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.events = []
        self.bridge = module.Bridge(self.events.append)
        self.addCleanup(self.bridge.close)
        self.profile = self.config / "test.prf"
        self.profile.write_text(f"root = {self.left}\nroot = {self.right}\n")

    def wait(self, phases, acknowledge=True):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            self.bridge.pump(0.01)
            if self.bridge.state["phase"] == "warning" and acknowledge:
                self.bridge.handle({"command": "acknowledge"})
            elif self.bridge.state["phase"] in phases:
                return self.bridge.state["phase"]
        self.fail(f"Timed out: {self.bridge.state}; tail: {self.bridge.tail}")

    def scan(self):
        self.bridge.start("test")
        return self.wait({"review", "complete", "partial", "error"})

    def command(self, command, **args):
        self.bridge.handle({"command": command, **args})

    def sync(self):
        self.command("finish")
        self.wait({"ready"})
        self.command("sync")
        return self.wait({"complete", "partial", "error"})

    def test_preview_holds_same_process_and_never_copies(self):
        (self.left / "hello world.txt").write_text("hello")
        self.assertEqual(self.scan(), "review")
        pid = self.bridge.child.pid
        self.assertEqual(self.bridge.state["items"][0]["path"], "hello world.txt")
        self.command("finish")
        self.wait({"ready"})
        self.assertEqual(self.bridge.child.pid, pid)
        self.assertFalse((self.right / "hello world.txt").exists())
        self.command("cancel")
        self.wait({"cancelled"})
        self.assertFalse((self.right / "hello world.txt").exists())

    def test_batch_auto_silent_and_repeat_profile_cannot_bypass_review(self):
        with self.profile.open("a") as f:
            f.write("batch = true\nauto = true\nsilent = true\nrepeat = 1\n")
        (self.left / "one").write_text("one")
        self.assertEqual(self.scan(), "review")
        self.assertFalse((self.right / "one").exists())
        self.assertEqual(self.sync(), "complete")
        self.assertEqual((self.right / "one").read_text(), "one")

    def test_bidirectional_sync_and_history(self):
        (self.left / "left.txt").write_text("left")
        (self.right / "right.txt").write_text("right")
        self.scan()
        self.assertEqual(len(self.bridge.state["items"]), 2)
        self.assertEqual(self.sync(), "complete")
        self.assertEqual((self.right / "left.txt").read_text(), "left")
        self.assertEqual((self.left / "right.txt").read_text(), "right")
        records = list((self.state_dir / "omason").glob("*.json"))
        record = json.loads(records[0].read_text())
        self.assertTrue(record["committed"])
        self.assertEqual(len(record["items"]), 2)
        self.assertIn("Copying", Path(record["logPath"]).read_text())
        self.assertEqual(records[0].stat().st_mode & 0o777, 0o600)

    def test_conflict_resolution_and_diff(self):
        (self.left / "conflict").write_text("left\n")
        (self.right / "conflict").write_text("right\n")
        self.scan()
        self.assertTrue(self.bridge.state["items"][0]["conflict"])
        self.command("diff")
        self.wait({"review"})
        self.assertIn("left", self.bridge.state["details"])
        self.assertIn("right", self.bridge.state["details"])
        self.command("choose", choice="right")
        self.wait({"ready"})
        self.assertEqual((self.right / "conflict").read_text(), "right\n")
        self.command("sync")
        self.assertEqual(self.wait({"complete", "error"}), "complete")
        self.assertEqual((self.right / "conflict").read_text(), "left\n")

    def test_skip_conflict_preserves_both_versions(self):
        (self.left / "conflict").write_text("left")
        (self.right / "conflict").write_text("right")
        self.scan()
        self.command("choose", choice="skip")
        self.assertEqual(self.wait({"partial", "error"}), "partial")
        self.assertEqual((self.left / "conflict").read_text(), "left")
        self.assertEqual((self.right / "conflict").read_text(), "right")

    def test_select_item_from_summary_and_skip(self):
        for name in ("alpha", "beta", "gamma"):
            (self.left / name).write_text(name)
        self.scan()
        self.command("finish")
        self.wait({"ready"})
        self.command("select", path="beta")
        self.wait({"review"})
        self.assertEqual(self.bridge.state["current"], "beta")
        self.command("choose", choice="skip")
        self.wait({"review"})
        self.command("finish")
        self.wait({"ready"})
        self.command("sync")
        self.assertEqual(self.wait({"partial", "error"}), "partial")
        self.assertTrue((self.right / "alpha").exists())
        self.assertFalse((self.right / "beta").exists())
        self.assertTrue((self.right / "gamma").exists())

    def test_deletion_warning_remains_explicit(self):
        (self.left / "one").write_text("one")
        self.scan()
        self.sync()
        (self.left / "one").unlink()
        self.bridge.start("test")
        self.wait({"warning"}, acknowledge=False)
        self.assertEqual(self.bridge.state["warning"], "big-delete")
        self.assertTrue((self.right / "one").exists())
        self.command("acknowledge")
        self.wait({"review"})
        self.assertEqual(self.sync(), "complete")
        self.assertFalse((self.right / "one").exists())

    def test_empty_replicas(self):
        self.assertEqual(self.scan(), "complete")
        self.assertFalse(self.bridge.committed)

    def test_details_and_unicode_paths(self):
        name = "café [notes] a very long file name.txt"
        (self.left / name).write_text("hello")
        self.scan()
        self.assertEqual(self.bridge.state["current"], name)
        self.command("details")
        self.wait({"review"})
        self.assertIn("size 5", self.bridge.state["details"])
        self.assertEqual(self.sync(), "complete")
        self.assertTrue((self.right / name).exists())

    def test_multiple_panels_cannot_start_duplicate_sessions(self):
        (self.left / "one").write_text("one")
        self.scan()
        peer = module.Bridge(lambda _: None)
        with self.assertRaisesRegex(ValueError, "Another omaSon"):
            peer.start("test")
        peer.close()

    def test_profile_creation_and_no_overwrite(self):
        self.command("create", name="New profile", left=str(self.left), right=str(self.right))
        new = self.config / "New profile.prf"
        original = new.read_text()
        self.assertIn("backup = Name *", original)
        with self.assertRaises(FileExistsError):
            self.command("create", name="New profile", left=str(self.left), right=str(self.right))
        self.assertEqual(new.read_text(), original)
        for name in ("../outside", "-batch", "bad/name"):
            with self.assertRaises(ValueError):
                self.command("create", name=name, left=str(self.left), right=str(self.right))

    def test_sync_is_rejected_until_final_prompt(self):
        (self.left / "one").write_text("one")
        self.scan()
        with self.assertRaises(ValueError):
            self.command("sync")
        self.assertFalse((self.right / "one").exists())

    def test_stdio_protocol_and_eof(self):
        process = subprocess.Popen([str(ROOT / "bin/omason"), "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = process.communicate('{"command":"catalog"}\n', timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertGreaterEqual(sum(json.loads(line)["type"] == "catalog" for line in stdout.splitlines()), 2)

    def test_helper_eof_cancels_review_without_transfer(self):
        (self.left / "one").write_text("one")
        process = subprocess.Popen([str(ROOT / "bin/omason"), "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write('{"command":"start","profile":"test"}\n')
            process.stdin.flush()
            for line in process.stdout:
                event = json.loads(line)
                if event.get("phase") == "warning":
                    process.stdin.write('{"command":"acknowledge"}\n')
                    process.stdin.flush()
                elif event.get("phase") == "review":
                    break
            process.stdin.close()
            process.stdin = None
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertIn('"phase": "cancelled"', stdout)
            self.assertFalse((self.right / "one").exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_child_error_releases_session_lock(self):
        with self.profile.open("a") as f:
            f.write("omason_unknown_preference = true\n")
        self.bridge.start("test")
        self.wait({"error"})
        self.assertIsNone(self.bridge.lock)
        self.assertIsNone(self.bridge.child)
        self.assertIn("omason_unknown_preference", self.bridge.tail)

    def test_restore_recommendation_from_summary(self):
        (self.left / "one").write_text("one")
        self.scan()
        self.command("finish")
        self.wait({"ready"})
        self.command("select", path="one")
        self.wait({"review"})
        self.command("choose", choice="default")
        self.wait({"ready"})
        self.command("sync")
        self.assertEqual(self.wait({"complete", "error"}), "complete")
        self.assertEqual((self.right / "one").read_text(), "one")

    def apply(self):
        self.command("apply")
        return self.wait({"complete", "partial", "error"})

    def test_set_rows_in_any_order_then_apply(self):
        for name in ("alpha", "beta", "gamma"):
            (self.left / name).write_text(name)
        self.scan()
        self.assertEqual(self.bridge.state["current"], "alpha")
        # Later row first (forward navigation), then an earlier one ('0').
        self.command("set", path="gamma", choice="skip")
        self.command("set", path="alpha", choice="skip")
        self.assertEqual(self.bridge.find("gamma")["arrow"], "<=?=>")
        self.assertEqual(self.apply(), "partial")
        self.assertFalse((self.right / "alpha").exists())
        self.assertEqual((self.right / "beta").read_text(), "beta")
        self.assertFalse((self.right / "gamma").exists())

    def test_set_conflict_direction_then_apply(self):
        (self.left / "conflict").write_text("left\n")
        (self.right / "conflict").write_text("right\n")
        (self.left / "other").write_text("other")
        self.scan()
        self.command("set", path="conflict", choice="left")
        self.assertEqual(self.apply(), "complete")
        self.assertEqual((self.left / "conflict").read_text(), "right\n")
        self.assertEqual((self.right / "other").read_text(), "other")

    def test_set_from_summary_and_reset(self):
        for name in ("alpha", "beta"):
            (self.left / name).write_text(name)
        self.scan()
        self.command("finish")
        self.wait({"ready"})
        self.command("set", path="beta", choice="skip")
        self.wait({"review", "ready"})
        self.command("set", path="beta", choice="default")
        self.assertEqual(self.bridge.find("beta")["arrow"], "---->")
        self.assertEqual(self.apply(), "complete")
        self.assertTrue((self.right / "beta").exists())

    def test_listing_metadata_totals_progress_and_result(self):
        (self.left / "five").write_text("12345")
        (self.right / "two").write_text("12")
        self.scan()
        five = self.bridge.find("five")
        self.assertEqual(five["recommended"], "---->")
        self.assertEqual(five["leftInfo"]["size"], 5)
        self.assertEqual(five["rightInfo"]["state"], "absent")
        self.assertEqual(self.apply(), "complete")
        state = self.bridge.state
        self.assertEqual(state["totals"]["items"], 2)
        self.assertEqual(state["totals"]["toRight"], "5 B")
        self.assertEqual(state["totals"]["toLeft"], "2 B")
        self.assertTrue(all(i.get("done") and not i.get("active") for i in state["items"]))
        self.assertIn(" of ", state["progress"]["bytes"])
        self.assertFalse(self.bridge.dirty)
        self.assertEqual(state["result"], {"transferred": 2, "skipped": 0, "failed": 0})
        self.assertEqual(state["message"], "Synced 2 items.")

    def test_apply_refuses_during_initial_scan_and_locks_choices(self):
        (self.left / "one").write_text("one")
        self.bridge.start("test")
        with self.assertRaises(ValueError):
            self.command("apply")
        self.wait({"review"})
        self.command("apply")
        with self.assertRaises(ValueError):
            self.command("set", path="one", choice="skip")
        self.assertEqual(self.wait({"complete", "error"}), "complete")

    def test_inspect_any_row_shows_diff(self):
        (self.left / "a").write_text("a")
        (self.left / "conflict").write_text("left side\n")
        (self.right / "conflict").write_text("right side\n")
        self.scan()
        self.command("inspect", path="conflict")
        deadline = time.monotonic() + 10
        while self.bridge.state["detailsPath"] != "conflict" and time.monotonic() < deadline:
            self.bridge.pump(0.01)
        self.wait({"review"})
        self.assertIn("left side", self.bridge.state["details"])

    def test_large_diff_keeps_its_start(self):
        (self.left / "big.txt").write_text("".join(f"left line {i:05d} with some padding text\n" for i in range(6000)))
        (self.right / "big.txt").write_text("".join(f"right line {i:05d} with some padding text\n" for i in range(6000)))
        self.scan()
        self.command("inspect", path="big.txt")
        deadline = time.monotonic() + 15
        while self.bridge.state["detailsPath"] != "big.txt" and time.monotonic() < deadline:
            self.bridge.pump(0.01)
        details = self.bridge.state["details"]
        self.assertTrue(self.bridge.state["detailsTruncated"])
        self.assertLessEqual(len(details), module.DETAILS_LIMIT)
        self.assertIn("+++ ", details)
        self.assertIn("line 00000", details)

    def test_missing_root_and_failed_file_are_explained(self):
        missing = self.config / "missing.prf"
        missing.write_text(f"root = {self.left}\nroot = {self.root}/not-mounted/Backup\n")
        self.bridge.start("missing")
        self.wait({"error"})
        self.assertIn("not-mounted/Backup is not available", self.bridge.state["message"])
        (self.left / "locked").mkdir()
        (self.left / "locked" / "a.txt").write_text("a")
        self.scan()
        self.apply()
        (self.left / "locked" / "b.txt").write_text("b")
        (self.left / "fine.txt").write_text("fine")
        os.chmod(self.right / "locked", 0o555)
        self.addCleanup(os.chmod, self.right / "locked", 0o755)
        self.scan()
        self.assertEqual(self.apply(), "error")
        failed = self.bridge.find("locked/b.txt")
        self.assertEqual((failed["failed"], failed["error"]), (True, "Permission denied"))
        self.assertTrue(self.bridge.find("fine.txt")["done"])
        self.assertEqual(self.bridge.state["result"]["failed"], 1)

    def test_catalog_replicas_and_last_run(self):
        (self.left / "one").write_text("one")
        self.scan()
        self.apply()
        self.events.clear()
        self.command("catalog")
        catalog = next(e for e in self.events if e["type"] == "catalog")
        profile = catalog["profiles"][0]
        self.assertEqual([r["kind"] for r in profile["replicas"]], ["local", "local"])
        self.assertEqual((profile["paths"], profile["ignores"]), ([], 0))
        self.assertTrue(all(r["online"] for r in profile["replicas"]))
        self.assertEqual(profile["last"]["phase"], "complete")
        self.assertEqual(profile["last"]["counts"]["toRight"], 1)
        self.assertEqual(catalog["history"][0]["result"]["transferred"], 1)


class FailureTests(unittest.TestCase):
    def test_failed_item_gets_its_reason(self):
        bridge = module.Bridge(lambda _: None)
        bridge.state["items"] = [{"path": "locked/b.txt", "arrow": "---->"}]
        bridge.track_progress("Failed [locked/b.txt]: Error in copying locally:\n"
                              "Permission denied [open(/r/locked/.unison.b.txt.2e5d.unison.tmp)]\n")
        item = bridge.find("locked/b.txt")
        self.assertEqual((item["failed"], item["done"], item["error"]), (True, False, "Permission denied"))

    def test_fatal_errors_read_as_sentences(self):
        text = "Error: Cannot find canonical name of /mnt/x/Backup: unable to cd either to it (/mnt/x/Backup: No such file or directory)\n"
        self.assertEqual(module.fatal(text), "/mnt/x/Backup is not available (no such file or directory).")
        self.assertEqual(module.fatal("Fatal error: Lost connection with the server\n"), "Lost connection with the server")
        self.assertEqual(module.fatal("all fine\n"), "")


class ProgressTests(unittest.TestCase):
    def test_begin_end_and_progress_lines(self):
        bridge = module.Bridge(lambda _: None)
        bridge.state["items"] = [{"path": "big file.mp4", "arrow": "---->"}, {"path": "a", "arrow": "---->"}]
        bridge.track_progress("[BGN] Copying big file.mp4 from /x from y/left to /r\n  0%  1/2  (5 B of 1.00 GiB)  --:-- ETA")
        self.assertTrue(bridge.find("big file.mp4")["active"])
        self.assertEqual(bridge.state["progress"], {"percent": 0, "done": 1, "total": 2, "bytes": "5 B of 1.00 GiB"})
        self.assertTrue(bridge.dirty)
        bridge.track_progress("  99%  1/2  ETA[END] Copying big file.mp4\n")
        item = bridge.find("big file.mp4")
        self.assertEqual((item["done"], item["active"]), (True, False))


class ReplicaTests(unittest.TestCase):
    def test_classifies_roots(self):
        ssh = module.replica("ssh://me@nas.local:22//srv/data")
        self.assertEqual((ssh["kind"], ssh["name"], ssh["path"]), ("ssh", "nas.local", "/srv/data"))
        self.assertEqual(module.replica("ssh://box/docs")["path"], "~/docs")
        drive = module.replica("/run/media/me/BACKUP/Gator")
        self.assertEqual((drive["kind"], drive["name"], drive["path"]), ("removable", "BACKUP", "/Gator"))
        docs = module.replica(str(Path.home() / "Documents"))
        self.assertEqual((docs["kind"], docs["name"], docs["path"]), ("local", "Documents", "~/Documents"))
        self.assertEqual(module.replica(str(Path.home()))["name"], "Home")
        same = module.replicas(["/srv/a/Docs", "/srv/b/Docs"])
        self.assertEqual([r["name"] for r in same], ["a/Docs", "b/Docs"])


if __name__ == "__main__":
    unittest.main()
