from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import stat
import tempfile
import time
from pathlib import Path

APP_ID = "proton-authenticator"
SESSION_FILE = "session.json"
SESSION_TTL = 300

class StateError(SystemExit):
    pass

def state_dir(create: bool = False) -> Path | None:
    xdg = os.environ.get("XDG_STATE_HOME", "")
    d = (Path(xdg) if xdg.startswith("/") else Path.home() / ".local/state") / APP_ID
    if create:
        d.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.mkdir(d, 0o700)
        except FileExistsError:
            pass
    try:
        st = os.lstat(d)
    except FileNotFoundError:
        return None
    if not stat.S_ISDIR(st.st_mode):
        raise StateError(f"{d}: not a directory (symlink?)")
    if st.st_uid != os.getuid():
        raise StateError(f"{d}: not owned by this user")
    if stat.S_IMODE(st.st_mode) & 0o077:
        raise StateError(f"{d}: must not be accessible to other users (chmod 700)")
    return d

def ensure_state_dir() -> Path:
    d = state_dir(True)
    assert d is not None
    return d

def atomic_write(directory: Path, name: str, data: bytes) -> None:
    fd, tmp = tempfile.mkstemp(prefix=f".{name}.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, directory / name)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

def read_private(directory: Path, name: str, limit: int) -> bytes | None:
    try:
        fd = os.open(directory / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            return None
        raw = fh.read(limit + 1)
    return raw if len(raw) <= limit else None

def unlock_configured() -> bool:
    d = state_dir(False)
    return d is not None and (d / "unlock.json").exists()

def session_dir() -> Path:
    rt = os.environ.get("XDG_RUNTIME_DIR", "")
    if rt.startswith("/") and os.path.isdir(rt):
        base = Path(rt) / APP_ID
        try:
            os.mkdir(base, 0o700)
        except FileExistsError:
            pass
        st = os.lstat(base)
        if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and not stat.S_IMODE(st.st_mode) & 0o077:
            return base
    return ensure_state_dir()

def session_dirs() -> list[Path]:
    out: list[Path] = []
    rt = os.environ.get("XDG_RUNTIME_DIR", "")
    if rt.startswith("/"):
        out.append(Path(rt) / APP_ID)
    d = state_dir(False)
    if d is not None:
        out.append(d)
    return out

def start_session() -> str:
    token = secrets.token_hex(32)
    payload = {"h": hashlib.sha256(token.encode()).hexdigest(), "exp": time.time() + SESSION_TTL}
    atomic_write(session_dir(), SESSION_FILE, json.dumps(payload).encode())
    return token

def end_session() -> None:
    try:
        os.unlink(session_dir() / SESSION_FILE)
    except FileNotFoundError:
        pass

def check_session(token: str) -> bool:
    if len(token) != 64:
        return False
    digest = hashlib.sha256(token.encode()).hexdigest()
    for d in session_dirs():
        raw = read_private(d, SESSION_FILE, 1024)
        if raw is None:
            continue
        try:
            data = json.loads(raw)
            if not isinstance(data, dict):
                continue
            good = hmac.compare_digest(digest, str(data.get("h", "")))
            if good and time.time() < float(data.get("exp", 0)):
                data["exp"] = time.time() + SESSION_TTL
                atomic_write(d, SESSION_FILE, json.dumps(data).encode())
                return True
        except (OSError, ValueError, TypeError):
            continue
    return False
