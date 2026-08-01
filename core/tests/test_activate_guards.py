"""The two under-lock guards in ``switch.activate``: capturing the outgoing
account's drifted credential before it is overwritten, and never activating an
older lineage than the local backup. Locks and every filesystem/Keychain
touchpoint are patched out; what's under test is which bytes end up written
where.
"""

from __future__ import annotations

import json
from contextlib import contextmanager

import pytest

from ccswitch_core import switch

OUTGOING = "11111111-1111-1111-1111-111111111111"
TARGET = "22222222-2222-2222-2222-222222222222"


def cred(refresh_token: str, expires_at: int) -> str:
    return json.dumps({
        "claudeAiOauth": {
            "accessToken": f"access-for-{refresh_token}",
            "refreshToken": refresh_token,
            "expiresAt": expires_at,
        }
    })


class FakeStore:
    def __init__(self) -> None:
        self.live = ""
        self.backups: dict[str, str] = {}
        self.activated: str | None = None

    def read_active_credentials(self) -> str:
        return self.live

    def read_account_credentials(self, account_uuid: str) -> str:
        return self.backups.get(account_uuid, "")

    def write_account_credentials(self, account_uuid: str, credentials: str) -> None:
        self.backups[account_uuid] = credentials

    def prepare_for_activation(self, target_credentials: str) -> str:
        return target_credentials

    def write_active_credentials(self, credentials: str) -> None:
        self.activated = credentials
        self.live = credentials


@pytest.fixture
def fake(monkeypatch):
    store = FakeStore()

    @contextmanager
    def no_lock(**_kwargs):
        yield

    monkeypatch.setattr(switch, "claude_config_lock", no_lock)
    monkeypatch.setattr(switch, "claude_credentials_lock", no_lock)
    monkeypatch.setattr(switch, "CredentialStore", lambda: store)
    monkeypatch.setattr(switch, "_read_claude_config", lambda: {})
    monkeypatch.setattr(switch, "_write_claude_config", lambda cfg: None)
    monkeypatch.setattr(switch, "_read_oauth_fragment", lambda uuid: None)
    monkeypatch.setattr(switch, "_write_oauth_fragment", lambda uuid, frag: None)
    monkeypatch.setattr(switch.local_store, "upsert_account", lambda *a, **k: None)
    monkeypatch.setattr(switch.local_store, "has_account", lambda uuid: True)
    return store


def test_switching_away_captures_the_outgoing_refresh(fake, monkeypatch):
    """Claude Code rotated the active account's token and the sync tick hasn't
    fired: switching away must bank that lineage, not overwrite the only copy."""
    monkeypatch.setattr(
        switch, "get_active_identity",
        lambda: {"account_uuid": OUTGOING, "email": "out@example.com", "organization_uuid": None},
    )
    fake.live = cred("rotated-by-claude-code", 500)
    fake.backups[OUTGOING] = cred("stale", 100)
    fake.backups[TARGET] = cred("target", 300)

    switch.activate(TARGET)

    assert "rotated-by-claude-code" in fake.backups[OUTGOING]
    assert "target" in fake.activated


def test_stale_pool_token_loses_to_a_newer_local_backup(fake, monkeypatch):
    """import-activate handed an older lineage than this Mac already holds
    (pool push failed upstream): activating it would log the account out."""
    monkeypatch.setattr(switch, "get_active_identity", lambda: None)
    fake.backups[TARGET] = cred("newer-local", 900)

    switch.activate(TARGET, credentials=cred("stale-pool", 100), email="t@example.com")

    assert "newer-local" in fake.activated


def test_fresher_pool_token_wins_over_an_old_backup(fake, monkeypatch):
    """The ordinary teammate-rotated case: the pool copy is ahead, use it and
    persist it as this machine's new local backup."""
    monkeypatch.setattr(switch, "get_active_identity", lambda: None)
    fake.backups[TARGET] = cred("old-local", 100)

    switch.activate(TARGET, credentials=cred("fresh-pool", 900), email="t@example.com")

    assert "fresh-pool" in fake.activated
    assert "fresh-pool" in fake.backups[TARGET]
