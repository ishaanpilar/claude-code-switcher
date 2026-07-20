"""Credential storage: Claude Code's *active* credential, and our own
per-account backup store keyed by ``anthropic_account_uuid``.

Adapted from claude-swap's credentials.py (MIT). Two real simplifications
from the source, both intentional:

1. **Keyed by account_uuid, not (slot_number, email).** claude-swap owns slot
   numbering locally; here, Supabase owns pool/account identity (see
   BUILD_PLAN.md section 4) and this process only ever gets an
   ``account_uuid`` handed to it. No slot table, no swap/move machinery.
2. **No sticky Keychain-unusable cache across calls.** claude-swap is a
   long-running daemon (menu bar/TUI) so it caches Keychain usability for the
   process lifetime. This process is a short-lived subprocess — one command,
   then exit — so there is no "process lifetime" worth caching against; each
   invocation just tries the Keychain and falls back to file on failure.

What is **not** simplified, because it is correctness-critical:

- The OAuth-vs-managed-API-key mutual exclusion Claude Code itself enforces.
- The shared-vs-account-owned credential field split (``SHARED_CREDENTIAL_KEYS``):
  activating a stored account must not clobber *live* machine-shared OAuth
  state (e.g. MCP server logins) with an older snapshot.
- Bumping an existing ``.credentials.json``'s mtime after a Keychain write, so
  a running Claude Code session hot-reloads instead of serving a memoized
  token until restart (claude-swap issue #86).
"""

from __future__ import annotations

import base64
import json
import logging
import os
import sys
import tempfile
from pathlib import Path

from ccswitch_core import macos_keychain
from ccswitch_core.exceptions import CredentialWriteError
from ccswitch_core.models import Platform
from ccswitch_core.paths import (
    get_claude_config_home,
    get_credentials_backup_dir,
    get_credentials_path,
    get_global_config_path,
)

_logger = logging.getLogger("ccswitch-core")

# Distinct from Claude Code's own service name so our per-account backups
# never collide with (or get deleted by) Claude Code itself.
SECURITY_SERVICE = "ccswitch-core"
CLAUDE_CODE_KEYCHAIN_SERVICE = "Claude Code-credentials"
CLAUDE_CODE_MANAGED_KEYCHAIN_SERVICE = "Claude Code"

SHARED_CREDENTIAL_KEYS = frozenset({
    "mcpOAuth",
    "mcpOAuthClientConfig",
    "mcpXaaIdp",
    "mcpXaaIdpConfig",
    "pluginSecrets",
})
ACCOUNT_CREDENTIAL_KEYS = frozenset({"claudeAiOauth", "trustedDeviceToken"})


def looks_like_api_key(credentials: str | None) -> bool:
    if not credentials:
        return False
    text = credentials.strip()
    return text.startswith("sk-ant-api") and not text.startswith("{")


def _credential_object(credentials: str | None) -> dict | None:
    if not credentials or looks_like_api_key(credentials):
        return None
    try:
        data = json.loads(credentials)
    except (json.JSONDecodeError, TypeError):
        return None
    return data if isinstance(data, dict) else None


def shared_credential_fields(credentials: str | None) -> dict | None:
    data = _credential_object(credentials)
    if data is None:
        return None
    return {key: data[key] for key in SHARED_CREDENTIAL_KEYS if key in data}


def merge_shared_credential_fields(target_credentials: str, shared_fields: dict) -> str:
    """The live machine's shared fields win over the target slot's snapshot;
    everything else in the target passes through untouched."""
    target = _credential_object(target_credentials)
    if target is None or "claudeAiOauth" not in target:
        return target_credentials
    composed = {k: v for k, v in target.items() if k not in SHARED_CREDENTIAL_KEYS}
    composed.update(shared_fields)
    return json.dumps(composed)


class CredentialStore:
    def __init__(self) -> None:
        self.platform = Platform.detect()

    # -- active credential (what Claude Code itself reads) -----------------

    def use_keychain(self) -> bool:
        return self.platform == Platform.MACOS

    def read_active_credentials(self) -> str:
        """Claude Code's active credential (OAuth JSON or a raw managed API
        key). ``""`` when nothing is stored anywhere."""
        if self.use_keychain():
            try:
                val = macos_keychain.get_password(
                    CLAUDE_CODE_KEYCHAIN_SERVICE, macos_keychain.keychain_account_name()
                )
                if val:
                    return val
            except macos_keychain.KEYCHAIN_ERRORS as e:
                _logger.warning("Keychain read failed, trying file: %s", e)

        cred_file = get_credentials_path()
        if cred_file.exists():
            text = cred_file.read_text(encoding="utf-8")
            if text.strip():
                return text

        if self.use_keychain():
            try:
                key = macos_keychain.get_password(
                    CLAUDE_CODE_MANAGED_KEYCHAIN_SERVICE, macos_keychain.keychain_account_name()
                )
                if key:
                    return key
            except macos_keychain.KEYCHAIN_ERRORS as e:
                _logger.warning("Managed-key Keychain read failed: %s", e)

        cfg = self._read_global_config()
        if cfg:
            key = cfg.get("primaryApiKey")
            if isinstance(key, str) and key:
                return key
        return ""

    def write_active_credentials(self, credentials: str) -> None:
        """Activate a credential as Claude Code's current login. Detects
        OAuth vs. managed-API-key from the payload shape and clears the
        other axis, mirroring Claude Code's own saveApiKey/removeApiKey."""
        if looks_like_api_key(credentials):
            self._write_managed_key(credentials.strip())
        else:
            self._write_oauth(credentials)
            self._clear_managed_key()

    def prepare_for_activation(self, target_credentials: str) -> str:
        """Compose the credential to activate: the target slot's bytes, with
        the live machine's SHARED_CREDENTIAL_KEYS substituted in so a stale
        restore can't clobber live MCP OAuth state."""
        live = self.read_active_credentials()
        live_shared = shared_credential_fields(live)
        if live_shared is None:
            return target_credentials
        return merge_shared_credential_fields(target_credentials, live_shared)

    def _write_oauth(self, credentials: str) -> None:
        if self.use_keychain():
            try:
                macos_keychain.set_password(
                    CLAUDE_CODE_KEYCHAIN_SERVICE, macos_keychain.keychain_account_name(), credentials
                )
                self._refresh_stale_credentials_file(credentials)
                return
            except macos_keychain.KEYCHAIN_ERRORS as e:
                _logger.warning("Keychain write failed, falling back to file: %s", e)

        try:
            self._write_active_credentials_file(credentials)
        except Exception as e:
            raise CredentialWriteError(f"Failed to write credentials: {e}")
        if self.platform == Platform.MACOS:
            try:
                macos_keychain.delete_password(
                    CLAUDE_CODE_KEYCHAIN_SERVICE, macos_keychain.keychain_account_name()
                )
            except Exception:
                pass  # best-effort; stale item, if it can't be cleared, is harmless-ish

    def _refresh_stale_credentials_file(self, credentials: str) -> None:
        """Rewrite an *already-present* .credentials.json with the same fresh
        bytes after a Keychain write, purely to bump its mtime — never
        create one when absent (Keychain-only users stay fileless)."""
        cred_file = get_credentials_path()
        if not cred_file.exists():
            return
        try:
            self._write_active_credentials_file(credentials)
        except Exception as e:
            _logger.warning("Could not refresh .credentials.json mtime: %s", e)

    def _write_managed_key(self, api_key: str) -> None:
        wrote_to_keychain = False
        if self.use_keychain():
            try:
                macos_keychain.set_password(
                    CLAUDE_CODE_MANAGED_KEYCHAIN_SERVICE, macos_keychain.keychain_account_name(), api_key
                )
                wrote_to_keychain = True
            except macos_keychain.KEYCHAIN_ERRORS as e:
                _logger.warning("Managed-key Keychain write failed, falling back: %s", e)

        approved = api_key.strip()[-20:]

        def _mutate(cfg: dict) -> None:
            responses = cfg.get("customApiKeyResponses")
            if not isinstance(responses, dict):
                responses = {}
            approved_list = responses.get("approved")
            if not isinstance(approved_list, list):
                approved_list = []
            if approved not in approved_list:
                approved_list.append(approved)
            responses["approved"] = approved_list
            responses.setdefault("rejected", [])
            cfg["customApiKeyResponses"] = responses
            if wrote_to_keychain:
                cfg.pop("primaryApiKey", None)
            else:
                cfg["primaryApiKey"] = api_key

        self._update_global_config(_mutate)
        self._clear_oauth()

    def _clear_managed_key(self) -> None:
        if self.platform == Platform.MACOS:
            try:
                macos_keychain.delete_password(
                    CLAUDE_CODE_MANAGED_KEYCHAIN_SERVICE, macos_keychain.keychain_account_name()
                )
            except Exception:
                pass
        cfg = self._read_global_config()
        if cfg is not None and cfg.get("primaryApiKey") is not None:
            def _drop(c: dict) -> None:
                c.pop("primaryApiKey", None)
            try:
                self._update_global_config(_drop)
            except Exception as e:
                _logger.warning("Failed to clear primaryApiKey: %s", e)

    def _clear_oauth(self) -> None:
        if self.platform == Platform.MACOS:
            try:
                macos_keychain.delete_password(
                    CLAUDE_CODE_KEYCHAIN_SERVICE, macos_keychain.keychain_account_name()
                )
            except Exception:
                pass
        cred_file = get_credentials_path()
        try:
            if cred_file.exists():
                cred_file.unlink()
        except OSError as e:
            _logger.warning("Failed to remove credentials file: %s", e)

    # -- global config (~/.claude.json) helpers -----------------------------

    def _read_global_config(self) -> dict | None:
        path = get_global_config_path()
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:
            _logger.warning("Failed to read global config: %s", e)
            return None
        return data if isinstance(data, dict) else None

    def _update_global_config(self, mutator) -> None:
        path = get_global_config_path()
        data = self._read_global_config() or {}
        mutator(data)
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

    def _write_active_credentials_file(self, credentials: str) -> None:
        cred_dir = get_claude_config_home()
        cred_dir.mkdir(parents=True, exist_ok=True)
        cred_file = cred_dir / ".credentials.json"
        fd, tmp_path = tempfile.mkstemp(dir=str(cred_dir), suffix=".tmp")
        try:
            os.write(fd, credentials.encode("utf-8"))
            os.close(fd)
            fd = -1
            os.replace(tmp_path, str(cred_file))
            os.chmod(str(cred_file), 0o600)
        except BaseException:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    # -- per-account backup, keyed by account_uuid --------------------------

    def _backup_enc_path(self, account_uuid: str) -> Path:
        return get_credentials_backup_dir() / f".creds-{account_uuid}.enc"

    def read_account_credentials(self, account_uuid: str) -> str:
        """``""`` when nothing is stored locally for this account_uuid."""
        enc_file = self._backup_enc_path(account_uuid)
        if enc_file.exists():
            try:
                encoded = enc_file.read_text(encoding="utf-8").strip()
                decoded = base64.b64decode(encoded, validate=True).decode("utf-8")
                if decoded:
                    return decoded
            except Exception as e:
                _logger.warning("Failed to read backup .enc: %s", e)
        if self.platform == Platform.MACOS:
            try:
                return macos_keychain.get_password(SECURITY_SERVICE, account_uuid) or ""
            except macos_keychain.KEYCHAIN_ERRORS as e:
                _logger.warning("Failed to read backup from Keychain: %s", e)
        return ""

    def write_account_credentials(self, account_uuid: str, credentials: str) -> None:
        if self.use_keychain():
            try:
                macos_keychain.set_password(SECURITY_SERVICE, account_uuid, credentials)
                # Keychain wins; drop a stale .enc so future reads can't be
                # shadowed by an older file-mode fallback copy.
                enc_file = self._backup_enc_path(account_uuid)
                if enc_file.exists():
                    try:
                        enc_file.unlink()
                    except OSError:
                        pass
                return
            except macos_keychain.KEYCHAIN_ERRORS as e:
                _logger.warning("Keychain backup write failed, falling back to file: %s", e)

        self._write_backup_enc(account_uuid, credentials)
        if self.platform == Platform.MACOS:
            try:
                macos_keychain.delete_password(SECURITY_SERVICE, account_uuid)
            except Exception:
                pass

    def _write_backup_enc(self, account_uuid: str, credentials: str) -> None:
        backup_dir = get_credentials_backup_dir()
        target = self._backup_enc_path(account_uuid)
        encoded = base64.b64encode(credentials.encode("utf-8")).decode("utf-8")
        fd, tmp_path = tempfile.mkstemp(dir=str(backup_dir), suffix=".tmp")
        try:
            os.write(fd, encoded.encode("utf-8"))
            os.close(fd)
            fd = -1
            os.replace(tmp_path, str(target))
            os.chmod(str(target), 0o600)
        except BaseException:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    def delete_account_credentials(self, account_uuid: str) -> None:
        enc_file = self._backup_enc_path(account_uuid)
        try:
            if enc_file.exists():
                enc_file.unlink()
        except Exception as e:
            _logger.warning("Failed to delete backup .enc: %s", e)
        if self.platform == Platform.MACOS:
            try:
                macos_keychain.delete_password(SECURITY_SERVICE, account_uuid)
            except Exception as e:
                _logger.warning("Failed to delete backup from Keychain: %s", e)
