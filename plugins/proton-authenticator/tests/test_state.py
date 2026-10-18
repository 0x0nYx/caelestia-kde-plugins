from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

BIN = Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(BIN))

import protonauth_state as state


def load_script(name: str):
    path = BIN / name
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def run_main(module, *argv: str, stdin: str = ""):
    out = io.StringIO()
    fake_stdin = types.SimpleNamespace(buffer=io.BytesIO(stdin.encode()))
    with mock.patch.object(sys, "argv", ["tool", *argv]), mock.patch.object(sys, "stdin", fake_stdin), \
            contextlib.redirect_stdout(out):
        rc = module.main()
    text = out.getvalue().strip()
    return rc, (json.loads(text) if text else None)


class StateTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state_home = root / "state"
        self.runtime = root / "run"
        self.state_home.mkdir(mode=0o700)
        self.runtime.mkdir(mode=0o700)
        patcher = mock.patch.dict(os.environ, {
            "XDG_STATE_HOME": str(self.state_home),
            "XDG_RUNTIME_DIR": str(self.runtime),
        })
        patcher.start()
        self.addCleanup(patcher.stop)


class StateDirTests(StateTestCase):
    def test_missing_dir_is_none_until_created(self):
        self.assertIsNone(state.state_dir())
        d = state.ensure_state_dir()
        self.assertEqual(d, self.state_home / state.APP_ID)
        self.assertEqual(stat.S_IMODE(os.lstat(d).st_mode), 0o700)
        self.assertEqual(state.state_dir(), d)

    def test_loose_permissions_are_refused(self):
        d = state.ensure_state_dir()
        os.chmod(d, 0o755)
        with self.assertRaises(state.StateError):
            state.state_dir()

    def test_symlinked_dir_is_refused(self):
        target = self.state_home / "elsewhere"
        target.mkdir(mode=0o700)
        os.symlink(target, self.state_home / state.APP_ID)
        with self.assertRaises(state.StateError):
            state.state_dir()

    def test_state_error_is_a_system_exit(self):
        self.assertTrue(issubclass(state.StateError, SystemExit))


class FileTests(StateTestCase):
    def test_atomic_write_is_private_and_leaves_no_temp_files(self):
        d = state.ensure_state_dir()
        state.atomic_write(d, "a.json", b"one")
        state.atomic_write(d, "a.json", b"two")
        self.assertEqual((d / "a.json").read_bytes(), b"two")
        self.assertEqual(stat.S_IMODE(os.lstat(d / "a.json").st_mode), 0o600)
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["a.json"])

    def test_atomic_write_cleans_up_on_failure(self):
        d = state.ensure_state_dir()
        with mock.patch.object(state.os, "replace", side_effect=OSError("boom")):
            with self.assertRaises(OSError):
                state.atomic_write(d, "a.json", b"x")
        self.assertEqual(list(d.iterdir()), [])

    def test_read_private_round_trip_and_limits(self):
        d = state.ensure_state_dir()
        state.atomic_write(d, "a.json", b"12345")
        self.assertEqual(state.read_private(d, "a.json", 5), b"12345")
        self.assertIsNone(state.read_private(d, "a.json", 4))
        self.assertIsNone(state.read_private(d, "missing.json", 10))

    def test_read_private_refuses_symlinks(self):
        d = state.ensure_state_dir()
        (self.state_home / "real").write_bytes(b"secret")
        os.symlink(self.state_home / "real", d / "a.json")
        self.assertIsNone(state.read_private(d, "a.json", 100))


class SessionTests(StateTestCase):
    def test_session_lives_in_runtime_dir(self):
        token = state.start_session()
        self.assertEqual(len(token), 64)
        self.assertTrue((self.runtime / state.APP_ID / state.SESSION_FILE).exists())
        self.assertFalse((self.state_home / state.APP_ID / state.SESSION_FILE).exists())

    def test_session_falls_back_to_state_dir(self):
        with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": ""}):
            token = state.start_session()
            self.assertTrue((self.state_home / state.APP_ID / state.SESSION_FILE).exists())
            self.assertTrue(state.check_session(token))

    def test_check_session_accepts_only_the_issued_token(self):
        token = state.start_session()
        self.assertTrue(state.check_session(token))
        self.assertFalse(state.check_session("0" * 64))
        self.assertFalse(state.check_session(token[:-1]))
        self.assertFalse(state.check_session(""))

    def test_check_session_slides_the_expiry(self):
        token = state.start_session()
        path = self.runtime / state.APP_ID / state.SESSION_FILE
        data = json.loads(path.read_text())
        data["exp"] = time.time() + 5
        path.write_text(json.dumps(data))
        os.chmod(path, 0o600)
        self.assertTrue(state.check_session(token))
        self.assertGreater(json.loads(path.read_text())["exp"], time.time() + state.SESSION_TTL - 5)

    def test_expired_session_is_rejected(self):
        token = state.start_session()
        path = self.runtime / state.APP_ID / state.SESSION_FILE
        data = json.loads(path.read_text())
        data["exp"] = time.time() - 1
        path.write_text(json.dumps(data))
        os.chmod(path, 0o600)
        self.assertFalse(state.check_session(token))

    def test_corrupt_session_file_is_rejected(self):
        token = state.start_session()
        path = self.runtime / state.APP_ID / state.SESSION_FILE
        for junk in ("not json", "[]", '{"h": "x", "exp": "soon"}'):
            path.write_text(junk)
            os.chmod(path, 0o600)
            self.assertFalse(state.check_session(token))

    def test_end_session_revokes_and_is_idempotent(self):
        token = state.start_session()
        state.end_session()
        self.assertFalse(state.check_session(token))
        state.end_session()


class PrefsTests(StateTestCase):
    def setUp(self):
        super().setUp()
        self.prefs = load_script("protonauth-prefs")

    def test_read_defaults_when_nothing_saved(self):
        rc, data = run_main(self.prefs, "read")
        self.assertEqual((rc, data), (0, {"pins": {}, "used": {}}))

    def test_write_then_read_cleans_input(self):
        payload = json.dumps({"pins": {"id:1": True, "id:2": False}, "used": {"id:1": 5, "id:2": "x"}, "extra": 1})
        rc, _ = run_main(self.prefs, "write", stdin=payload)
        self.assertEqual(rc, 0)
        _, data = run_main(self.prefs, "read")
        self.assertEqual(data, {"pins": {"id:1": True}, "used": {"id:1": 5}})
        path = self.state_home / state.APP_ID / "prefs.json"
        self.assertEqual(stat.S_IMODE(os.lstat(path).st_mode), 0o600)

    def test_unknown_command_is_a_usage_error(self):
        out = io.StringIO()
        with contextlib.redirect_stderr(out):
            rc, _ = run_main(self.prefs, "nope")
        self.assertEqual(rc, 2)


class UnlockTests(StateTestCase):
    def setUp(self):
        super().setUp()
        self.unlock = load_script("protonauth-unlock")
        patcher = mock.patch.object(self.unlock, "N", 2**4)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_cmd(self, *argv, stdin=""):
        return run_main(self.unlock, *argv, stdin=stdin)

    def test_status_reports_unset_then_set(self):
        self.assertEqual(self.run_cmd("status")[1]["status"], "unset")
        self.run_cmd("create", stdin="secret1\n")
        self.assertEqual(self.run_cmd("status")[1], {"ok": True, "status": "set", "token": "", "waitSec": 0})

    def test_create_validates_length_and_refuses_overwrite(self):
        rc, reply = self.run_cmd("create", stdin="abc\n")
        self.assertEqual((rc, reply["status"], reply["ok"]), (1, "invalid", False))
        rc, reply = self.run_cmd("create", stdin="secret1\n")
        self.assertEqual((rc, reply["status"], reply["ok"]), (0, "unlocked", True))
        self.assertTrue(state.check_session(reply["token"]))
        rc, reply = self.run_cmd("create", stdin="another1\n")
        self.assertEqual((rc, reply["status"]), (1, "exists"))

    def test_verify_good_and_bad_codes(self):
        self.run_cmd("create", stdin="secret1\n")
        rc, reply = self.run_cmd("verify", stdin="secret1\n")
        self.assertEqual((rc, reply["status"]), (0, "unlocked"))
        self.assertRegex(reply["token"], r"^[0-9a-f]{64}$")
        rc, reply = self.run_cmd("verify", stdin="wrong\n")
        self.assertEqual((rc, reply["status"], reply["token"]), (1, "bad", ""))

    def test_verify_without_a_code_set_is_missing(self):
        rc, reply = self.run_cmd("verify", stdin="secret1\n")
        self.assertEqual((rc, reply["status"]), (1, "missing"))

    def test_repeated_failures_trigger_a_wait(self):
        self.run_cmd("create", stdin="secret1\n")
        statuses = [self.run_cmd("verify", stdin="wrong\n")[1]["status"] for _ in range(5)]
        self.assertEqual(statuses, ["bad"] * 4 + ["wait"])
        rc, reply = self.run_cmd("verify", stdin="secret1\n")
        self.assertEqual((rc, reply["status"]), (1, "wait"))
        self.assertGreater(reply["waitSec"], 0)
        self.assertLessEqual(reply["waitSec"], 31)

    def test_lock_ends_the_session(self):
        _, reply = self.run_cmd("create", stdin="secret1\n")
        rc, locked = self.run_cmd("lock")
        self.assertEqual((rc, locked["status"]), (0, "locked"))
        self.assertFalse(state.check_session(reply["token"]))

    def test_reset_needs_the_account_password(self):
        self.run_cmd("create", stdin="secret1\n")
        with mock.patch.object(self.unlock, "pam_check", return_value=False):
            rc, reply = self.run_cmd("reset", stdin="nope\n")
        self.assertEqual((rc, reply["status"]), (1, "bad"))
        with mock.patch.object(self.unlock, "pam_check", return_value=True):
            rc, reply = self.run_cmd("reset", stdin="root-pass\n")
        self.assertEqual((rc, reply["status"], reply["ok"]), (0, "reset", True))
        self.assertEqual(self.run_cmd("status")[1]["status"], "unset")

    def test_every_reply_has_the_same_four_fields(self):
        self.run_cmd("create", stdin="secret1\n")
        for argv, stdin in ((("status",), ""), (("verify",), "wrong\n"), (("verify",), "secret1\n"), (("lock",), "")):
            _, reply = self.run_cmd(*argv, stdin=stdin)
            self.assertEqual(sorted(reply), ["ok", "status", "token", "waitSec"])


class ListUnlockGateTests(StateTestCase):
    def setUp(self):
        super().setUp()
        self.lister = load_script("protonauth_list.py")

    def gate(self, token: str):
        fake_stdin = types.SimpleNamespace(buffer=io.BytesIO((token + "\n").encode()))
        with mock.patch.object(sys, "stdin", fake_stdin):
            self.lister.require_unlock_token()

    def test_no_unlock_code_means_no_gate(self):
        self.gate("")

    def test_gate_requires_a_live_session_once_a_code_is_set(self):
        unlock = load_script("protonauth-unlock")
        with mock.patch.object(unlock, "N", 2**4):
            _, reply = run_main(unlock, "create", stdin="secret1\n")
        self.gate(reply["token"])
        with self.assertRaises(self.lister.Err) as ctx:
            self.gate("0" * 64)
        self.assertEqual(ctx.exception.code, "LOCKED")
        state.end_session()
        with self.assertRaises(self.lister.Err):
            self.gate(reply["token"])

    def test_unsafe_state_dir_is_reported_not_crashed(self):
        d = state.ensure_state_dir()
        os.chmod(d, 0o755)
        with self.assertRaises(self.lister.Err) as ctx:
            self.gate("")
        self.assertEqual(ctx.exception.code, "STATE_UNSAFE")


if __name__ == "__main__":
    unittest.main()
