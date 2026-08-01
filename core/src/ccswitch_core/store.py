"""Local index of accounts this machine has credential backups for.

Deliberately thin: it holds only what's needed to answer "what do I have
locally" (identity, email, when captured). It is not the pool. Pool membership,
share mode and claims live in Supabase and are owned by the Swift side; this
file only has to survive this Mac being offline.

Keyed by ``anthropic_account_uuid`` (the same identity Claude Code records in
``~/.claude.json``'s ``oauthAccount``), never by email, so a display-email
collision can't merge two distinct accounts.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from ccswitch_core.models import get_timestamp
from ccswitch_core.paths import get_core_data_root

_SCHEMA_VERSION = 1


def _index_path() -> Path:
    return get_core_data_root() / "accounts.json"


def _empty() -> dict:
    return {"schemaVersion": _SCHEMA_VERSION, "accounts": {}}


def load() -> dict:
    path = _index_path()
    if not path.exists():
        return _empty()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return _empty()
    if not isinstance(data, dict) or not isinstance(data.get("accounts"), dict):
        return _empty()
    return data


def _save(data: dict) -> None:
    path = _index_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        os.write(fd, json.dumps(data, indent=2).encode("utf-8"))
        os.close(fd)
        fd = -1
        os.replace(tmp_path, str(path))
        os.chmod(str(path), 0o600)
    except BaseException:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def list_accounts() -> list[dict]:
    """Every locally-known account, oldest-captured first."""
    data = load()
    rows = [{"account_uuid": uuid, **info} for uuid, info in data["accounts"].items()]
    rows.sort(key=lambda r: r.get("captured_at", ""))
    return rows


def has_account(account_uuid: str) -> bool:
    """Whether this machine has a backup registered for ``account_uuid``."""
    return account_uuid in load()["accounts"]


def upsert_account(account_uuid: str, *, email: str, organization_uuid: str | None) -> None:
    data = load()
    existing = data["accounts"].get(account_uuid, {})
    data["accounts"][account_uuid] = {
        "email": email,
        "organization_uuid": organization_uuid,
        "captured_at": existing.get("captured_at") or get_timestamp(),
        "updated_at": get_timestamp(),
    }
    _save(data)


def remove_account(account_uuid: str) -> bool:
    data = load()
    if account_uuid not in data["accounts"]:
        return False
    del data["accounts"][account_uuid]
    _save(data)
    return True
