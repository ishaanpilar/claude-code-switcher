"""Capture and activate accounts: the credential-critical execution path.

Extracted from claude-swap's switcher.py ``perform_switch`` (MIT), simplified
to operate on a single ``account_uuid`` handed in by the caller, since Supabase
and Swift own slot semantics now, instead of a local slot table.

One design choice worth calling out: we only merge the small ``oauthAccount``
fragment into ``~/.claude.json``, never snapshot or restore the whole file. The
rest of that file (project trust, MCP server config, local settings) is
machine-local and must not travel with an account switch. The original
``ccswitch.sh`` got this right with ``jq '.oauthAccount = $oauth'``.
claude-swap's fuller per-slot config snapshot solves a different problem, full
local-state parity across slots on one machine, which doesn't apply where the
pool spans machines.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path

from ccswitch_core import oauth
from ccswitch_core.claude_locks import claude_config_lock, claude_credentials_lock
from ccswitch_core.credentials import CredentialStore, looks_like_api_key
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
    ``oauthAccount``: a cheap local read, no network, no lock. None when nobody
    is logged in or the field is missing or incomplete."""
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
    """Back up the currently logged-in account so it can be switched back to
    later: the local half of both the manual add flow and auto-capture on new
    login. Idempotent, since capturing an already-known account just refreshes
    its stored token, which is correct: a fresh login is always at least as
    current as whatever was stored."""
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


def _refresh_token_fingerprint(credentials: str | None) -> str | None:
    """Short digest of a credential's ``refreshToken``: enough to tell two
    lineages apart, never enough to reconstruct one. Safe to log."""
    if not credentials:
        return None
    data = oauth.extract_oauth_data(credentials)
    if not isinstance(data, dict):
        return None
    token = data.get("refreshToken")
    if not isinstance(token, str) or not token:
        return None
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


def _expires_at(credentials: str | None) -> int:
    """``expiresAt`` in epoch ms, or 0 when absent. Only ever compared against
    another credential for the *same* account on this machine, so the fact that
    it was computed from a local clock (see oauth.try_refresh_oauth_credentials)
    doesn't matter here -- both sides came from this same clock."""
    if not credentials:
        return 0
    data = oauth.extract_oauth_data(credentials) or {}
    value = data.get("expiresAt")
    return value if isinstance(value, int) else 0


def _sync_result(identity: dict | None, synced: bool, reason: str) -> dict:
    return {
        "synced": synced,
        "reason": reason,
        "account_uuid": (identity or {}).get("account_uuid"),
        "email": (identity or {}).get("email"),
    }


def _drift_check(store: CredentialStore) -> tuple[dict | None, str | None, str]:
    """Has Claude Code's live credential moved on from our backup?

    Returns ``(identity, live_credentials, reason)``. ``live_credentials`` is
    non-None only when a sync should actually happen; ``reason`` always explains
    the outcome, synced or not.
    """
    identity = get_active_identity()
    if identity is None:
        return None, None, "no_active_account"
    account_uuid = identity["account_uuid"]

    # A first-ever login is auto-capture's job (see AutoCaptureController), not
    # ours. Syncing an account we have no backup for would silently adopt it.
    if not local_store.has_account(account_uuid):
        return identity, None, "not_locally_known"

    live = store.read_active_credentials()
    if not live or looks_like_api_key(live):
        return identity, None, "no_oauth_credential"
    live_fp = _refresh_token_fingerprint(live)
    if live_fp is None:
        return identity, None, "no_refresh_token"

    backup = store.read_account_credentials(account_uuid)
    if live_fp == _refresh_token_fingerprint(backup):
        return identity, None, "already_current"
    # The backup can legitimately be *ahead* of what's live: the auto-switch
    # engine refreshes and persists a token before it attempts activation (see
    # the save-credentials command). Overwriting the newer lineage with the
    # older one would re-arm the exact failure this function exists to prevent.
    if _expires_at(backup) > _expires_at(live):
        return identity, None, "backup_is_newer"

    return identity, live, "drifted"


def sync_active_credential() -> dict:
    """Copy the *live* Claude Code credential into this machine's backup for the
    active account, whenever Claude Code has moved on from what we stored.

    Claude Code refreshes its own OAuth token as it runs, and the refresh token
    rotates on every refresh, so the copy taken at activation goes stale within
    hours of ordinary use. Nothing else in this app notices: the capture watcher
    watches ``~/.claude.json``, which a token refresh does not touch, and on
    macOS the credential itself lives in the Keychain, which emits no filesystem
    events at all. Left unsynced the backup rots, switching back to the account
    activates a spent refresh token, and Claude Code drops to the login screen.

    Only ever touches the account that is *currently* active, since that is the
    only one whose live credential exists on this machine.

    Returns ``{"synced": bool, "reason": str, ...}`` rather than raising: every
    "nothing to do" outcome here is routine, not an error.
    """
    store = CredentialStore()

    # Cheap unlocked pre-check first. This runs on a timer, and in the steady
    # state the two copies match, so taking Claude Code's own lockfiles on every
    # tick would put contention on a running session for nothing. The
    # authoritative read happens under the lock, only once drift actually shows.
    identity, live, reason = _drift_check(store)
    if live is None:
        return _sync_result(identity, False, reason)

    with claude_config_lock(), claude_credentials_lock():
        # Re-check under the lock rather than trusting the pre-check. A switch
        # may have landed in between, and the identity in ~/.claude.json is what
        # names the backup we are about to write: pairing a stale identity with
        # a fresh credential would overwrite one account's backup using another
        # account's token, destroying the first.
        identity, live, reason = _drift_check(store)
        if live is None:
            return _sync_result(identity, False, reason)
        store.write_account_credentials(identity["account_uuid"], live)

    return _sync_result(identity, True, "updated")


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
      token handed in fresh, typically decrypted by Swift from a teammate's
      shared Supabase entry. Also persisted as this machine's own local
      backup afterward, so a subsequent bare ``switch`` back to it works
      offline. ``email``/``organization_uuid`` (from the Supabase row, since
      an import may be the first time this machine has ever seen the
      account) seed the local index when supplied.

    Holds both of Claude Code's own lockfiles for the duration. See
    claude_locks.py's module docstring for why: without it, a switch racing a
    live Claude Code token refresh can be silently overwritten.
    """
    store = CredentialStore()

    if credentials is None:
        credentials = store.read_account_credentials(account_uuid)
        if not credentials:
            raise AccountNotFoundError(
                f"No local credentials for account {account_uuid}: "
                "import it first (import-activate) or add-current while logged into it"
            )

    with claude_config_lock(), claude_credentials_lock():
        # Two guards before anything is overwritten, both under Claude Code's
        # own locks so nothing can move between check and write.
        #
        # 1. Capture the *outgoing* account's live credential if Claude Code
        #    refreshed it past our backup. The periodic sync-active tick closes
        #    this window most of the time, but a switch landing inside it would
        #    overwrite the only copy of that lineage, and the backup left
        #    behind would hold a spent refresh token: the exact "log in again"
        #    failure this app exists to prevent.
        out_identity, out_live, _ = _drift_check(store)
        if out_live is not None:
            store.write_account_credentials(out_identity["account_uuid"], out_live)

        # 2. Never activate an older lineage than the one this machine already
        #    holds. The pool ciphertext can lag this Mac's own backup (a push
        #    failed, or guard 1 just ran for this same account), and expiresAt
        #    orders two lineages of one account well enough: lifetimes are
        #    hours, cross-machine clock skew is seconds.
        local_backup = store.read_account_credentials(account_uuid)
        if local_backup and _expires_at(local_backup) > _expires_at(credentials):
            credentials = local_backup

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
    Supabase: the Swift caller removes the pool row separately, and must check
    no claim or active-use conflict exists first."""
    store = CredentialStore()
    store.delete_account_credentials(account_uuid)
    frag = _oauth_fragment_path(account_uuid)
    if frag.exists():
        try:
            frag.unlink()
        except OSError:
            pass
    return local_store.remove_account(account_uuid)
