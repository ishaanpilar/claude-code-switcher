"""Typed errors. Every one carries a stable ``code`` so the Swift side can
switch on it instead of string-matching a message (see __main__.py's JSON
error envelope: ``{"ok": false, "error": {"code": ..., "message": ...}}``)."""

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


class RefreshFailedError(CoreError):
    code = "refresh_failed"


class UsageFetchError(CoreError):
    code = "usage_fetch_error"
