"""``ccswitch-core`` CLI: one command per process invocation.

Spawned by the Swift app (see app/Sources/ClaudeCodeSwitcher/CoreBridge) via
``Process``. Always prints exactly one JSON object to stdout and exits 0 on
success, or non-zero with ``{"ok": false, "error": {...}}`` on failure, never a
Python traceback. Logging goes to stderr only, so it never pollutes the JSON
contract Swift parses.

Command surface:
  snapshot                                  active identity + locally-known accounts
  add-current                               capture the currently logged-in account
  switch        --account-uuid U            activate a locally-backed-up account
  import-activate --account-uuid U [--email E] [--organization-uuid O]
                                             activate a token from stdin (e.g. decrypted
                                             from a teammate's shared Supabase entry)
  export-token  --account-uuid U            print a locally-backed-up account's token
  read-usage    [--account-uuid U]          fetch usage; token from stdin or local backup
  refresh-token                             refresh a token given on stdin
  save-credentials --account-uuid U         persist a token (stdin) as this account's local
                                             backup without activating it
  remove        --account-uuid U            delete this machine's local backup
"""

from __future__ import annotations

import argparse
import json
import logging
import sys

from ccswitch_core import oauth, switch
from ccswitch_core.credentials import CredentialStore
from ccswitch_core.exceptions import CoreError

logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    stream=sys.stderr,
)


def _read_stdin() -> str:
    data = sys.stdin.read()
    return data.strip()


def _ok(**fields) -> int:
    print(json.dumps({"ok": True, **fields}))
    return 0


def _err(code: str, message: str) -> int:
    print(json.dumps({"ok": False, "error": {"code": code, "message": message}}))
    return 1


def cmd_snapshot(_args: argparse.Namespace) -> int:
    return _ok(**switch.snapshot())


def cmd_add_current(_args: argparse.Namespace) -> int:
    account = switch.capture_current()
    return _ok(account=account)


def cmd_switch(args: argparse.Namespace) -> int:
    account = switch.activate(args.account_uuid)
    return _ok(account=account)


def cmd_import_activate(args: argparse.Namespace) -> int:
    token = _read_stdin()
    if not token:
        return _err("empty_token", "No token provided on stdin")
    account = switch.activate(
        args.account_uuid,
        credentials=token,
        email=args.email,
        organization_uuid=args.organization_uuid,
    )
    return _ok(account=account)


def cmd_export_token(args: argparse.Namespace) -> int:
    store = CredentialStore()
    token = store.read_account_credentials(args.account_uuid)
    if not token:
        return _err("account_not_found", f"No local credentials for account {args.account_uuid}")
    return _ok(token=token)


def cmd_read_usage(args: argparse.Namespace) -> int:
    token: str | None = None
    if not sys.stdin.isatty():
        candidate = _read_stdin()
        if candidate:
            token = candidate
    if token is None:
        if not args.account_uuid:
            return _err("missing_input", "Provide a token on stdin or --account-uuid")
        store = CredentialStore()
        token = store.read_account_credentials(args.account_uuid)
        if not token:
            return _err("account_not_found", f"No local credentials for account {args.account_uuid}")

    access_token = oauth.extract_oauth_data(token)
    if access_token is None:
        return _err("not_oauth", "Stored credential is not an OAuth token (likely an API key, which has no usage data)")
    access_token_str = access_token.get("accessToken")
    if not access_token_str:
        return _err("no_access_token", "Stored OAuth credential has no accessToken")

    try:
        raw = oauth.request_usage_data(access_token_str)
    except Exception as e:
        return _err("usage_fetch_error", str(e))
    return _ok(usage=oauth.build_usage_result(raw))


def cmd_refresh_token(_args: argparse.Namespace) -> int:
    token = _read_stdin()
    if not token:
        return _err("empty_token", "No token provided on stdin")
    outcome = oauth.try_refresh_oauth_credentials(token)
    if outcome.credentials is None:
        return _err(outcome.error or "refresh_failed", "Token refresh failed")
    return _ok(token=outcome.credentials, token_account=outcome.token_account)


def cmd_save_credentials(args: argparse.Namespace) -> int:
    """Persists a token to this account's local backup without activating it: no
    ~/.claude.json write, no Claude Code lock held. Exists for the auto-switch engine's
    freshen-before-activate step. A refresh_token is typically single-use, so a refreshed
    OAuth token must be saved the instant the refresh succeeds. If the subsequent activate
    fails for an unrelated reason (lock contention, a transient error) and the fresh token
    was never persisted, the next attempt reads the already-consumed refresh_token back out
    of storage and is guaranteed to fail with invalid_grant. Saving first means a failed
    activate only means "retry the activate", never "this account is now permanently dead".
    """
    token = _read_stdin()
    if not token:
        return _err("empty_token", "No token provided on stdin")
    store = CredentialStore()
    store.write_account_credentials(args.account_uuid, token)
    return _ok()


def cmd_remove(args: argparse.Namespace) -> int:
    removed = switch.remove_local(args.account_uuid)
    return _ok(removed=removed)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ccswitch-core")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("snapshot").set_defaults(func=cmd_snapshot)
    sub.add_parser("add-current").set_defaults(func=cmd_add_current)

    p = sub.add_parser("switch")
    p.add_argument("--account-uuid", required=True)
    p.set_defaults(func=cmd_switch)

    p = sub.add_parser("import-activate")
    p.add_argument("--account-uuid", required=True)
    p.add_argument("--email")
    p.add_argument("--organization-uuid")
    p.set_defaults(func=cmd_import_activate)

    p = sub.add_parser("export-token")
    p.add_argument("--account-uuid", required=True)
    p.set_defaults(func=cmd_export_token)

    p = sub.add_parser("read-usage")
    p.add_argument("--account-uuid")
    p.set_defaults(func=cmd_read_usage)

    sub.add_parser("refresh-token").set_defaults(func=cmd_refresh_token)

    p = sub.add_parser("save-credentials")
    p.add_argument("--account-uuid", required=True)
    p.set_defaults(func=cmd_save_credentials)

    p = sub.add_parser("remove")
    p.add_argument("--account-uuid", required=True)
    p.set_defaults(func=cmd_remove)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except CoreError as e:
        return _err(e.code, str(e))
    except Exception as e:  # last resort: must still be valid JSON, never a traceback
        logging.getLogger("ccswitch-core").exception("unhandled error")
        return _err("internal_error", str(e))


if __name__ == "__main__":
    sys.exit(main())
