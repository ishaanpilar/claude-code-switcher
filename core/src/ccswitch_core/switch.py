"""Capture and activate accounts — the credential-critical execution path.

Extracted from claude-swap's switcher.py ``perform_switch`` (MIT), simplified
to operate on a single ``account_uuid`` handed in by the caller (Supabase/
Swift owns slot semantics now — see BUILD_PLAN.md section 2) instead of a
local slot table.

Design choice worth calling out: we only ever merge the small ``oauthAccount``
fragment into ``~/.claude.json``, never snapshot/restore the whole file. The
rest of that file (project trust, MCP server config, local settings) is
machine-local and must never travel with an account switch — the original
``ccswitch.sh`` got this right (``jq '.oauthAccount = $oauth'``) and
claude-swap's fuller per-slot config snapshot is solving a different problem
(full local-state parity across *slots on one machine*) that doesn't apply
here, where the pool spans machines.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from ccswitch_core.claude_locks import claude_config_lock, claude_credentials_lock
from ccswitch_core.credentials import CredentialStore
from ccswitch_core.exceptions import AccountNotFoundError, NoActiveAccountError, NoCredentialsError
from ccswitch_core.paths import get_core_data_root, get_global_config_path
from ccswitch_core import store as local_store


def _oauth_fragment_path(account_uuid: str) -> Path:
    d = get_core_data_root() / "oauth_accounts"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{account_uuid}.json"


def _read_oauth_fragment(account_uuid: str) -> dict | None:
    path = _oauth_fragment_path(account_uuid)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    return data if isinstance(data, dict) else None


def _write_oauth_fragment(account_uuid: str, fragment: dict) -> None:
    path = _oauth_fragment_path(account_uuid)
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        os.write(fd, json.dumps(fragment, indent=2).encode("utf-8"))
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


def _read_claude_config() -> dict:
    path = get_global_config_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_claude_config(data: dict) -> None:
    """Caller must hold ``claude_config_lock``."""
    path = get_global_config_path()
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


def get_active_identity() -> dict | None:
    """The currently-logged-in account's identity from ``~/.claude.json``'s
    ``oauthAccount`` — a cheap local read, no network, no lock (read-only).
    None when nobody is logged in or the field is missing/incomplete."""
    cfg = _read_claude_config()
    oauth_account = cfg.get("oauthAccount")
    if not isinstance(oauth_account, dict):
        return None
    account_uuid = oauth_account.get("accountUuid")
    email = oauth_account.get("emailAddress")
    if not account_uuid or not email:
        return None
    return {
        "account_uuid": account_uuid,
        "email": email,
        "organization_uuid": oauth_account.get("organizationUuid"),
    }


def snapshot() -> dict:
    """Everything the CLI's ``snapshot`` command reports: active identity +
    every account this machine has local credential backups for."""
    return {
        "active": get_active_identity(),
        "known_accounts": local_store.list_accounts(),
    }


def capture_current() -> dict:
    """Back up the *currently logged-in* account so it can be switched back
    to later — the local half of both ``cswap add``'s manual flow and the
    auto-capture-on-new-login feature (BUILD_PLAN.md section 6). Idempotent:
    capturing an already-known account just refreshes its stored token,
    which is correct — a fresh login is always at least as current as
    whatever was stored."""
    store = CredentialStore()
    active_creds = store.read_active_credentials()
    if not active_creds:
        raise NoCredentialsError("No credentials found for the currently active account")

    identity = get_active_identity()
    if identity is None:
        raise NoActiveAccountError("No active Claude account found (missing oauthAccount)")

    account_uuid = identity["account_uuid"]
    store.write_account_credentials(account_uuid, active_creds)
    local_store.upsert_account(
        account_uuid, email=identity["email"], organization_uuid=identity.get("organization_uuid")
    )
    cfg = _read_claude_config()
    oauth_account = cfg.get("oauthAccount")
    if isinstance(oauth_account, dict):
        _write_oauth_fragment(account_uuid, oauth_account)

    return identity


def activate(
    account_uuid: str,
    *,
    credentials: str | None = None,
    email: str | None = None,
    organization_uuid: str | None = None,
) -> dict:
    """Activate an account. Two calling shapes:

    - ``credentials=None`` (the ``switch`` command): read this machine's own
      local backup for ``account_uuid``. Raises AccountNotFoundError if this
      machine has never captured it.
    - ``credentials=<plaintext token>`` (the ``import-activate`` command): a
      token handed in fresh — typically decrypted by Swift from a teammate's
      shared Supabase entry. Also persisted as this machine's own local
      backup afterward, so a subsequent bare ``switch`` back to it works
      offline. ``email``/``organization_uuid`` (from the Supabase row, since
      an import may be the first time this machine has ever seen the
      account) seed the local index when supplied.

    Holds both of Claude Code's own lockfiles for the duration — see
    claude_locks.py's module docstring for why this matters: without it, a
    switch racing a live Claude Code token refresh can be silently
    overwritten.
    """
    store = CredentialStore()

    if credentials is None:
        credentials = store.read_account_credentials(account_uuid)
        if not credentials:
            raise AccountNotFoundError(
                f"No local credentials for account {account_uuid} — "
                "import it first (import-activate) or add-current while logged into it"
            )

    with claude_config_lock(), claude_credentials_lock():
        merged = store.prepare_for_activation(credentials)
        store.write_active_credentials(merged)

        fragment = _read_oauth_fragment(account_uuid)
        if fragment is None and email:
            fragment = {"accountUuid": account_uuid, "emailAddress": email}
            if organization_uuid:
                fragment["organizationUuid"] = organization_uuid
        if fragment is not None:
            cfg = _read_claude_config()
            cfg["oauthAccount"] = fragment
            _write_claude_config(cfg)

    # Persist locally *after* activation succeeds, so a partial failure above
    # never leaves the local backup ahead of what's actually active.
    store.write_account_credentials(account_uuid, merged)
    resolved_email = (fragment or {}).get("emailAddress") or email
    if resolved_email:
        local_store.upsert_account(
            account_uuid,
            email=resolved_email,
            organization_uuid=(fragment or {}).get("organizationUuid") or organization_uuid,
        )
        _write_oauth_fragment(account_uuid, fragment or {
            "accountUuid": account_uuid, "emailAddress": resolved_email,
        })

    return {
        "account_uuid": account_uuid,
        "email": resolved_email,
        "organization_uuid": (fragment or {}).get("organizationUuid") or organization_uuid,
    }


def remove_local(account_uuid: str) -> bool:
    """Delete this machine's local backup for an account. Does not touch
    Supabase — the caller (Swift) removes the pool row separately, and must
    check no claim/active-use conflict exists first."""
    store = CredentialStore()
    store.delete_account_credentials(account_uuid)
    frag = _oauth_fragment_path(account_uuid)
    if frag.exists():
        try:
            frag.unlink()
        except OSError:
            pass
    return local_store.remove_account(account_uuid)
