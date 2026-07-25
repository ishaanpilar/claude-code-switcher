"""Typed errors. Each carries a stable ``code`` so the Swift side can switch on
it instead of string-matching a message. See __main__.py's error envelope:
``{"ok": false, "error": {"code": ..., "message": ...}}``.

Failures that never propagate as exceptions are not modelled here: token
refresh and usage fetch both report through their own return values
(``oauth.RefreshOutcome``) or an ``_err()`` code emitted at the CLI boundary.
"""

from __future__ import annotations


class CoreError(Exception):
    code = "core_error"


class NoActiveAccountError(CoreError):
    code = "no_active_account"


class NoCredentialsError(CoreError):
    code = "no_credentials"


class AccountNotFoundError(CoreError):
    code = "account_not_found"


class CredentialWriteError(CoreError):
    code = "credential_write_error"


class ClaudeCodeLockTimeout(CoreError):
    code = "lock_timeout"
