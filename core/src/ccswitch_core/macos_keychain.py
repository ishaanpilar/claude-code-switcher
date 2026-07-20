"""macOS Keychain access via the ``security`` CLI.

Ported near-verbatim from claude-swap (MIT). A small wrapper around the
system ``security`` tool instead of the third-party ``keyring`` library:
Keychain items are created and read by the same stable ``security`` binary
Claude Code itself uses, so creator == reader and there is no permission
prompt.

The read/write/delete shapes mirror Claude Code's own implementation
(``utils/secureStorage/macOsKeychainStorage.ts``):

- ``set_password`` hex-encodes the value (``-X``) and pipes the command
  through ``security -i`` (stdin) so the secret never appears in process
  argv. Falls back to argv only when the command would overflow ``security
  -i``'s 4096-byte stdin line buffer.
- ``get_password`` uses ``find-generic-password ... -w`` and treats exit code
  44 as "not found" (returns ``None``); any other non-zero exit raises so
  callers can tell a genuine miss apart from a locked/denied/unavailable
  Keychain.

Caveat: values must be printable text (credentials here are ASCII JSON).
"""

from __future__ import annotations

import os
import subprocess

SECURITY_STDIN_LINE_LIMIT = 4096 - 64
_NOT_FOUND_RC = 44
_TIMEOUT = 5.0
_SECURITY = "/usr/bin/security"


class KeychainError(Exception):
    """A ``security`` invocation failed for a reason other than "not found"."""


KEYCHAIN_ERRORS = (KeychainError, subprocess.TimeoutExpired, OSError)


def keychain_account_name() -> str:
    """Account name for Keychain items, mirroring Claude Code's own
    ``getUsername()`` so we key the same item it does."""
    user = os.environ.get("USER")
    if user:
        return user
    try:
        import pwd

        return pwd.getpwuid(os.geteuid()).pw_name
    except Exception:
        return "claude-code-user"


def _quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def get_password(service: str, account: str) -> str | None:
    try:
        result = subprocess.run(
            [_SECURITY, "find-generic-password", "-a", account, "-w", "-s", service],
            capture_output=True,
            text=True,
            timeout=_TIMEOUT,
        )
    except subprocess.TimeoutExpired as e:
        raise KeychainError(
            f"security find-generic-password timed out after {_TIMEOUT}s"
        ) from e
    if result.returncode == 0:
        return result.stdout.removesuffix("\n")
    if result.returncode == _NOT_FOUND_RC:
        return None
    raise KeychainError(
        f"security find-generic-password failed (rc={result.returncode}): "
        f"{result.stderr.strip()}"
    )


def set_password(service: str, account: str, password: str) -> None:
    hex_value = password.encode("utf-8").hex()
    command = (
        f"add-generic-password -U -a {_quote(account)} -s {_quote(service)} "
        f"-X {hex_value}\n"
    )
    try:
        if len(command.encode("utf-8")) <= SECURITY_STDIN_LINE_LIMIT:
            result = subprocess.run(
                [_SECURITY, "-i"],
                input=command,
                capture_output=True,
                text=True,
                timeout=_TIMEOUT,
            )
        else:
            result = subprocess.run(
                [
                    _SECURITY, "add-generic-password", "-U",
                    "-a", account, "-s", service, "-X", hex_value,
                ],
                capture_output=True,
                text=True,
                timeout=_TIMEOUT,
            )
    except subprocess.TimeoutExpired as e:
        raise KeychainError(
            f"security add-generic-password timed out after {_TIMEOUT}s"
        ) from e
    if result.returncode != 0:
        raise KeychainError(
            f"security add-generic-password failed (rc={result.returncode}): "
            f"{result.stderr.strip()}"
        )


def delete_password(service: str, account: str) -> None:
    try:
        result = subprocess.run(
            [_SECURITY, "delete-generic-password", "-a", account, "-s", service],
            capture_output=True,
            text=True,
            timeout=_TIMEOUT,
        )
    except subprocess.TimeoutExpired as e:
        raise KeychainError(
            f"security delete-generic-password timed out after {_TIMEOUT}s"
        ) from e
    if result.returncode in (0, _NOT_FOUND_RC):
        return
    raise KeychainError(
        f"security delete-generic-password failed (rc={result.returncode}): "
        f"{result.stderr.strip()}"
    )
