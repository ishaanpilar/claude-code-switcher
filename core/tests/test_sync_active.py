"""Drift detection for the active account's stored credential.

The decision logic lives in ``switch._drift_check``, which is pure apart from
the three things patched here (active identity, local index, credential store).
That is deliberate: the write it guards is destructive, so the branch that
decides *whether* to write is worth testing without any Keychain or filesystem
involvement at all.
"""

from __future__ import annotations

import json

import pytest

from ccswitch_core import switch

ACCOUNT = "887b82d9-b546-41dd-9c7b-0b133cde4399"
IDENTITY = {"account_uuid": ACCOUNT, "email": "user@example.com", "organization_uuid": None}


def cred(refresh_token: str, expires_at: int) -> str:
    return json.dumps({
        "claudeAiOauth": {
            "accessToken": f"access-for-{refresh_token}",
            "refreshToken": refresh_token,
            "expiresAt": expires_at,
            "scopes": ["user:inference"],
        }
    })


class FakeStore:
    def __init__(self, live: str = "", backups: dict[str, str] | None = None) -> None:
        self._live = live
        self._backups = backups or {}

    def read_active_credentials(self) -> str:
        return self._live

    def read_account_credentials(self, account_uuid: str) -> str:
        return self._backups.get(account_uuid, "")


@pytest.fixture
def patched(monkeypatch):
    """Active account present and locally known, unless a test overrides it."""
    monkeypatch.setattr(switch, "get_active_identity", lambda: IDENTITY)
    monkeypatch.setattr(switch.local_store, "has_account", lambda uuid: uuid == ACCOUNT)
    return monkeypatch


def test_no_active_account(patched):
    patched.setattr(switch, "get_active_identity", lambda: None)
    identity, live, reason = switch._drift_check(FakeStore(live=cred("r1", 100)))
    assert (identity, live, reason) == (None, None, "no_active_account")


def test_unknown_account_is_left_to_auto_capture(patched):
    """A first-ever login must not be silently adopted here."""
    patched.setattr(switch.local_store, "has_account", lambda uuid: False)
    _, live, reason = switch._drift_check(FakeStore(live=cred("r1", 100)))
    assert live is None
    assert reason == "not_locally_known"


@pytest.mark.parametrize("live_value", ["", "sk-ant-api03-not-an-oauth-token"])
def test_non_oauth_live_credential_is_skipped(patched, live_value):
    """A managed API key has no refresh lineage; it must not overwrite a backup."""
    store = FakeStore(live=live_value, backups={ACCOUNT: cred("r1", 100)})
    _, live, reason = switch._drift_check(store)
    assert live is None
    assert reason == "no_oauth_credential"


def test_matching_lineage_is_a_no_op(patched):
    same = cred("r1", 100)
    _, live, reason = switch._drift_check(FakeStore(live=same, backups={ACCOUNT: same}))
    assert live is None
    assert reason == "already_current"


def test_drift_is_detected_and_returns_the_live_credential(patched):
    """Claude Code refreshed past our copy: the whole point of this command."""
    live_cred = cred("r2", 200)
    store = FakeStore(live=live_cred, backups={ACCOUNT: cred("r1", 100)})
    identity, live, reason = switch._drift_check(store)
    assert reason == "drifted"
    assert live == live_cred
    assert identity["account_uuid"] == ACCOUNT


def test_missing_backup_for_a_known_account_syncs(patched):
    """Known account whose backup was lost: adopting the live credential is a repair."""
    _, live, reason = switch._drift_check(FakeStore(live=cred("r2", 200), backups={}))
    assert reason == "drifted"
    assert live is not None


def test_newer_backup_is_never_clobbered(patched):
    """The auto-switch engine persists a refreshed token *before* activating it, so the
    backup legitimately runs ahead of the live credential in that window. Overwriting it
    would discard the newer lineage and re-arm the failure this command exists to prevent."""
    store = FakeStore(live=cred("r1", 100), backups={ACCOUNT: cred("r2", 200)})
    _, live, reason = switch._drift_check(store)
    assert live is None
    assert reason == "backup_is_newer"


def test_fingerprint_identifies_lineage_without_exposing_it():
    token = "super-secret-refresh-token"
    fp = switch._refresh_token_fingerprint(cred(token, 100))
    assert fp is not None and len(fp) == 16
    assert token not in fp
    assert fp == switch._refresh_token_fingerprint(cred(token, 999))  # expiry is not identity
    assert fp != switch._refresh_token_fingerprint(cred("different-token", 100))


@pytest.mark.parametrize("value", [None, "", "not json", json.dumps({"claudeAiOauth": {}})])
def test_fingerprint_of_unusable_input_is_none(value):
    assert switch._refresh_token_fingerprint(value) is None


def test_expires_at_defaults_to_zero_when_absent():
    assert switch._expires_at(None) == 0
    assert switch._expires_at(json.dumps({"claudeAiOauth": {"refreshToken": "r"}})) == 0
    assert switch._expires_at(cred("r", 1234)) == 1234
