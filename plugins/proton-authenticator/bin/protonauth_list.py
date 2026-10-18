#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import selectors
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True

import protonauth_state as state

__version__ = "3.0.0"

try:
    import pyotp
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
except ImportError as _imp_err:
    _IMPORT_ERROR: ImportError | None = _imp_err
else:
    _IMPORT_ERROR = None

DATA_DIR = Path.home() / ".local/share/me.proton.authenticator"
HKDF_INFO = b"authenticator;storage-key"
ITEM_AAD = b"authenticator;item"
SERVICE = "com.proton.authenticator"

SECRET_TOOL = "/usr/bin/secret-tool" if os.path.exists("/usr/bin/secret-tool") else "secret-tool"
ADAPTER_ID_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,127}$")

TMP_PREFIX = "navauth-idb-"

HELPER_TIMEOUT_SEC = 20
SECRET_TOOL_TIMEOUT_SEC = 10
SECRET_MAX_BYTES = 64
MAX_ENTRIES = 1000
MAX_LABEL_CHARS = 256
MAX_ID_CHARS = 128
MAX_MESSAGE_CHARS = 200
MAX_OUTPUT_BYTES = 1024 * 1024

DEFAULT_WINDOW = 3
MAX_WINDOW = 5

class Err(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message

def find_idb() -> Path:
    root = DATA_DIR / "databases" / "indexeddb"
    if not root.exists():
        raise Err("VAULT_UNREADABLE", f"missing IndexedDB under {root}")
    candidates: list[Path] = []
    for p in root.rglob("IndexedDB.sqlite3"):
        try:
            con = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
            con.create_collation("IDBKEY", lambda a, b: (a > b) - (a < b))
            names = {r[0] for r in con.execute("SELECT name FROM ObjectStoreInfo")}
            con.close()
            if {"items", "storageKey"} <= names:
                candidates.append(p)
        except (sqlite3.Error, OSError):
            continue
    if not candidates:
        raise Err("VAULT_UNREADABLE", "no IndexedDB with items/storageKey stores")
    return max(candidates, key=lambda p: p.stat().st_mtime)

@contextlib.contextmanager
def vault_snapshot(src: Path):

    rt = os.environ.get("XDG_RUNTIME_DIR", "")
    base = rt if rt.startswith("/") and os.path.isdir(rt) and os.access(rt, os.W_OK) else None
    tmpdir = Path(tempfile.mkdtemp(prefix=TMP_PREFIX, dir=base))
    try:
        tmp = tmpdir / "idb.sqlite3"
        os.close(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        src_con = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        dst_con = sqlite3.connect(tmp)
        try:
            src_con.backup(dst_con)
        finally:
            dst_con.close()
            src_con.close()
        yield tmp
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

def extract_arraybuffer_after(marker: bytes, blob: bytes) -> bytes:
    i = blob.find(marker)
    if i < 0:
        raise Err("UNSUPPORTED_SCHEMA", f"missing marker {marker!r}")
    j = i + len(marker)
    if j >= len(blob) or blob[j] != 0x16:
        raise Err("UNSUPPORTED_SCHEMA", "expected ArrayBuffer tag after marker")
    j += 1
    if blob[j] != 0x02:
        raise Err("UNSUPPORTED_SCHEMA", "unexpected ArrayBuffer header")
    j += 1
    a, b = struct.unpack_from("<QQ", blob, j)
    j += 16
    if a != 0 or blob[j] != 0x15:
        raise Err("UNSUPPORTED_SCHEMA", "unexpected ArrayBuffer view header")
    j += 1
    (c,) = struct.unpack_from("<Q", blob, j)
    j += 8
    if c != b:
        raise Err("UNSUPPORTED_SCHEMA", "ArrayBuffer length mismatch")
    return blob[j : j + b]

def extract_hb_string_after(key: bytes, blob: bytes) -> str | None:
    pat = struct.pack("<I", 0x80000000 | len(key)) + key
    i = blob.find(pat)
    if i < 0:
        return None
    j = i + len(pat)
    if blob[j] != 0x10:
        return None
    j += 1
    (raw,) = struct.unpack_from("<I", blob, j)
    j += 4
    if raw in (0xFFFFFFFE, 0xFFFFFFFF):
        return ""
    if not (raw & 0x80000000):
        return None
    n = raw & 0xFFFFFF
    return blob[j : j + n].decode("utf-8")

def extract_i32_after(key: bytes, blob: bytes) -> int | None:
    pat = struct.pack("<I", 0x80000000 | len(key)) + key
    i = blob.find(pat)
    if i < 0:
        return None
    j = i + len(pat)
    if blob[j] != 0x05:
        return None
    j += 1
    return struct.unpack_from("<i", blob, j)[0]

def load_rows(db: Path, store: str) -> list[bytes]:
    con = sqlite3.connect(db)
    con.create_collation("IDBKEY", lambda a, b: (a > b) - (a < b))
    oid = dict(con.execute("SELECT name, id FROM ObjectStoreInfo"))[store]
    out: list[bytes] = []
    for (val,) in con.execute("SELECT value FROM Records WHERE objectStoreID=?", (oid,)):
        out.append(val if isinstance(val, bytes) else val.encode("latin1"))
    con.close()
    return out

def run_bounded(argv: list[str], limit: int, timeout: float) -> tuple[int | None, bytes]:

    deadline = time.monotonic() + timeout
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    try:
        assert proc.stdout is not None
        fd = proc.stdout.fileno()
        buf = b""
        with selectors.DefaultSelector() as sel:
            sel.register(fd, selectors.EVENT_READ)
            while len(buf) <= limit:
                left = deadline - time.monotonic()
                if left <= 0 or not sel.select(left):
                    raise subprocess.TimeoutExpired(argv, timeout)
                chunk = os.read(fd, limit + 1 - len(buf))
                if not chunk:
                    break
                buf += chunk
        if len(buf) > limit:
            return None, buf[: limit + 1]
        return proc.wait(timeout=max(0.1, deadline - time.monotonic())), buf
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        if proc.stdout is not None:
            proc.stdout.close()

def read_keyring(adapter_key_id: str) -> bytes:

    if not ADAPTER_ID_RE.match(adapter_key_id):
        raise Err("UNSUPPORTED_SCHEMA", "unexpected adapterKeyId format")
    try:
        rc, secret = run_bounded(
            [SECRET_TOOL, "lookup", "service", SERVICE, "username", adapter_key_id],
            SECRET_MAX_BYTES, SECRET_TOOL_TIMEOUT_SEC,
        )
    except FileNotFoundError as e:
        raise Err("DEPS_MISSING", "secret-tool not found (install package: libsecret)") from e
    except subprocess.TimeoutExpired as e:
        raise Err("HELPER_TIMEOUT", "secret-tool did not answer (keyring prompt open?)") from e
    if rc is None:
        raise Err("DECRYPT_FAILED", "unexpected key length (too long)")
    if rc != 0:
        if not secret_service_present():
            raise Err("NO_SECRET_SERVICE",
                      "no Secret Service on the session bus (enable KWallet's Secret Service or start a keyring)")
        raise Err("KEY_MISSING", f"no Secret Service item for {adapter_key_id}")
    if not secret:
        raise Err("KEYRING_LOCKED", "empty secret — unlock the session keyring")
    if len(secret) != 32:
        raise Err("DECRYPT_FAILED", f"unexpected key length {len(secret)}")
    return secret

def fallback_key_candidates(sk: bytes) -> list[bytes]:

    import base64
    import binascii
    out: list[bytes] = []
    try:
        out.append(extract_arraybuffer_after(b"unsafe_key", sk))
    except Exception:
        pass
    try:
        text = extract_hb_string_after(b"unsafe_key", sk)
    except Exception:
        text = None
    if text:
        for decode in (base64.b64decode, base64.urlsafe_b64decode, binascii.unhexlify):
            try:
                out.append(decode(text + "=" * (-len(text) % 4) if decode is not binascii.unhexlify else text))
            except (ValueError, binascii.Error):
                pass
        out.append(text.encode())
    return [k for k in out if len(k) == 32]

def try_decrypt(aesgcm, ct: bytes):
    for ivlen in (12, 16):
        try:
            return json.loads(aesgcm.decrypt(ct[:ivlen], ct[ivlen:], ITEM_AAD).decode())
        except (InvalidTag, ValueError):
            continue
    return None

def resolve_aesgcm(idb: Path, sk: bytes, salt: bytes, adapter: str):

    candidates: list[tuple[bytes, str]] = []
    keyring_err: Err | None = None
    try:
        candidates.append((read_keyring(adapter), "keyring"))
    except Err as e:
        keyring_err = e
    candidates += [(k, "fallback") for k in fallback_key_candidates(sk)]
    if not candidates:
        raise keyring_err or Err("KEY_MISSING", "no key found")
    items = load_rows(idb, "items")
    probe = None
    if items:
        try:
            probe = extract_arraybuffer_after(b"__encryptedData", items[0])
        except Exception:
            probe = None
    for secret, source in candidates:
        aes = AESGCM(HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=HKDF_INFO).derive(secret))
        if probe is None or try_decrypt(aes, probe) is not None:
            return aes, source

    raise keyring_err or Err("DECRYPT_FAILED", "no stored key decrypts the vault")

def list_entries(window: int) -> dict:
    with vault_snapshot(find_idb()) as idb:
        sk_rows = load_rows(idb, "storageKey")
        if not sk_rows:
            raise Err("VAULT_UNREADABLE", "storageKey store empty")
        sk = sk_rows[0]
        salt = extract_arraybuffer_after(b"salt", sk)
        adapter = extract_hb_string_after(b"adapterKeyId", sk)
        if not adapter:
            raise Err("UNSUPPORTED_SCHEMA", "adapterKeyId missing")
        aesgcm, key_source = resolve_aesgcm(idb, sk, salt, adapter)

        now = int(time.time())
        entries: list[dict] = []
        skipped: list[str] = []
        items = load_rows(idb, "items")
        if len(items) > MAX_ENTRIES:
            raise Err("OUTPUT_TOO_LARGE", f"more than {MAX_ENTRIES} entries")
        for vb in items:
            issuer = extract_hb_string_after(b"issuer", vb) or ""
            name = extract_hb_string_after(b"name", vb)
            if name is None:
                name = ""
            order = extract_i32_after(b"order", vb)
            entry_id = extract_hb_string_after(b"id", vb) or ""
            ct = extract_arraybuffer_after(b"__encryptedData", vb)
            obj = try_decrypt(aesgcm, ct)
            if obj is None:
                raise Err("DECRYPT_FAILED", f"AES-GCM failed for {issuer or entry_id}")

            try:
                seed = obj.get("secret")
                if not seed and obj.get("uri"):
                    seed = pyotp.parse_uri(obj["uri"]).secret
                if not seed:
                    raise ValueError("no secret")

                seed = re.sub(r"[\s-]", "", str(seed)).upper().rstrip("=")
                period = int(obj.get("period") or 30)
                digits = int(obj.get("digits") or 6)

                if not (1 <= digits <= 10 and 1 <= period <= 86400):
                    raise ValueError("unsupported digits/period")
                totp = pyotp.TOTP(seed, digits=digits, interval=period)
                window_codes = code_window(totp, period, now, window)
            except Exception:
                skipped.append(str(issuer or entry_id)[:MAX_LABEL_CHARS])
                continue
            entries.append(
                {
                    "id": str(entry_id)[:MAX_ID_CHARS],
                    "issuer": str(issuer or obj.get("issuer") or "")[:MAX_LABEL_CHARS],
                    "account": str(name if name != "" else (obj.get("name") or ""))[:MAX_LABEL_CHARS],
                    "period": period,
                    "digits": digits,
                    "order": order if order is not None else 0,
                    **window_codes,
                }
            )
        if skipped and not entries:
            raise Err("UNSUPPORTED_SCHEMA", f"could not read any entry ({len(skipped)} skipped)")
        entries.sort(key=lambda e: (-e["order"], e["issuer"].lower(), e["account"].lower()))
        return {
            "ok": True,
            "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
            "entries": entries,
            "error": None,
            "warning": "FALLBACK_KEY" if key_source == "fallback" else None,
            "skipped": skipped,
        }

def code_window(totp, period: int, now: int, window: int) -> dict:

    counter = now // period
    return {
        "counter": counter,
        "codes": [totp.at((counter + k) * period) for k in range(window)],
    }

def fail(code: str, message: str) -> dict:
    return {
        "ok": False,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "entries": [],
        "error": {"code": code, "message": str(message)[:MAX_MESSAGE_CHARS]},
    }

def check() -> dict:

    if shutil.which(SECRET_TOOL) is None:
        raise Err("DEPS_MISSING", "secret-tool not found (install package: libsecret)")
    idb = find_idb()
    with vault_snapshot(idb) as tmp:
        sk_rows = load_rows(tmp, "storageKey")
        if not sk_rows:
            raise Err("VAULT_UNREADABLE", "storageKey store empty")
        adapter = extract_hb_string_after(b"adapterKeyId", sk_rows[0])
        if not adapter:
            raise Err("UNSUPPORTED_SCHEMA", "adapterKeyId missing")
        salt = extract_arraybuffer_after(b"salt", sk_rows[0])
        _aes, key_source = resolve_aesgcm(tmp, sk_rows[0], salt, adapter)
        items = len(load_rows(tmp, "items"))
    return {
        "ok": True,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "entries": [],
        "error": None,
        "warning": "FALLBACK_KEY" if key_source == "fallback" else None,
        "check": {"vault": str(idb), "items": items, "keySource": key_source},
    }

DEMO_ACCOUNTS = [
    ("GitHub", "octocat@example.com", "JBSWY3DPEHPK3PXP", 30, 6),
    ("Proton", "demo@proton.me", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 30, 6),
    ("Google", "jane.doe@example.com", "KRSXG5CTMVRXEZLUKN2XAZLSKNSWG4TFOQ", 30, 6),
    ("AWS", "root@example.org", "MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43U", 30, 6),
    ("Discord", "jane#0001", "ONSWG4TFORZWK3DUMVZXG5DFON2A", 30, 6),
    ("Tailscale", "jane@example.net", "OBQXG43XN5ZGIZLYMFWXA3DF", 30, 8),
]

def demo(window: int) -> dict:
    now = int(time.time())
    entries = []
    for i, (issuer, account, seed, period, digits) in enumerate(DEMO_ACCOUNTS):
        totp = pyotp.TOTP(seed, digits=digits, interval=period)
        entries.append({
            "id": f"demo-{i}", "issuer": issuer, "account": account,
            "period": period, "digits": digits, "order": 0,
            **code_window(totp, period, now, window),
        })
    return {"ok": True, "demo": True,
            "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
            "entries": entries, "error": None}

def _exit_on_signal(signum, _frame):

    raise SystemExit(128 + signum)

def _on_alarm(_signum, _frame):

    raise Err("HELPER_TIMEOUT", f"helper took longer than {HELPER_TIMEOUT_SEC} s")

def emit(payload: dict) -> None:

    out = json.dumps(payload, separators=(",", ":"))
    if len(out.encode("utf-8")) > MAX_OUTPUT_BYTES:
        out = json.dumps(fail("OUTPUT_TOO_LARGE", f"output over {MAX_OUTPUT_BYTES} bytes"),
                         separators=(",", ":"))
    print(out)

def harden_process() -> None:

    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except (ImportError, ValueError, OSError):
        pass
    try:
        import ctypes
        ctypes.CDLL(None, use_errno=True).prctl(4, 0, 0, 0, 0)
    except Exception:
        pass

def secret_service_present() -> bool:

    for argv in (["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
                  "--object-path", "/org/freedesktop/DBus", "--method",
                  "org.freedesktop.DBus.NameHasOwner", "org.freedesktop.secrets"],):
        try:
            rc, out = run_bounded(argv, 256, 3)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return True
        if rc == 0:
            return b"true" in out
    return True

def require_unlock_token() -> None:
    """If an unlock code is set, refuse to emit codes without a live session token (stdin, 1st line)."""
    try:
        if not state.unlock_configured():
            return
        token = sys.stdin.buffer.readline(200).decode("ascii", "ignore").strip()
        if state.check_session(token):
            return
    except state.StateError as e:
        raise Err("STATE_UNSAFE", str(e)) from e
    raise Err("LOCKED", "Unlock code required")

def main() -> int:
    harden_process()
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, _exit_on_signal)
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(HELPER_TIMEOUT_SEC)
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="verify dependencies, vault and keyring access; prints no codes")
    ap.add_argument("--demo", action="store_true",
                    help="print fake demo accounts (for screenshots); never touches the vault")
    ap.add_argument("--window", type=int, default=DEFAULT_WINDOW,
                    help=f"codes per entry, current one first (1-{MAX_WINDOW})")
    ap.add_argument("--version", action="version", version=f"protonauth-list {__version__}")
    args = ap.parse_args()
    window = max(1, min(MAX_WINDOW, args.window))
    if _IMPORT_ERROR is not None:
        emit(fail("DEPS_MISSING", f"{_IMPORT_ERROR} (install: python-cryptography python-pyotp)"))
        return 1
    try:
        if args.demo:
            emit(demo(window))
            return 0
        if args.check:
            emit(check())
            return 0
        require_unlock_token()
        payload = list_entries(window)
        for e in payload["entries"]:
            if "secret" in e:
                raise Err("DECRYPT_FAILED", "refusing to emit secret field")
        emit(payload)
        return 0
    except Err as e:
        emit(fail(e.code, e.message))
        return 1
    except Exception as e:

        import traceback
        line = traceback.extract_tb(e.__traceback__)[-1].lineno if e.__traceback__ else 0
        emit(fail("DECRYPT_FAILED", f"internal error ({type(e).__module__}.{type(e).__name__} at line {line})"))
        return 1
    finally:
        signal.alarm(0)

if __name__ == "__main__":
    sys.exit(main())
