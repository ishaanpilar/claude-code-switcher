"""OAuth token refresh and usage-API access.

Trimmed from claude-swap's oauth.py (MIT): kept refresh plus the usage
fetch/normalize pair. Dropped the pace, relevant-windows and formatting helpers
that only the CLI's own text rendering needed, since the Swift side owns all
display formatting now.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone

from ccswitch_core import __version__

OAUTH_BETA_HEADER = "oauth-2025-04-20"
OAUTH_TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
USER_AGENT = f"ccswitch-core/{__version__}"

_logger = logging.getLogger("ccswitch-core")


def extract_oauth_data(credentials: str) -> dict | None:
    try:
        data = json.loads(credentials)
    except json.JSONDecodeError:
        return None
    oauth = data.get("claudeAiOauth")
    return oauth if isinstance(oauth, dict) else None


@dataclass(frozen=True)
class RefreshOutcome:
    """``error`` classifies failure so callers can tell a dead refresh-token
    lineage (``invalid_grant``: permanent, quarantine) from a network blip
    (``transient``: retry later)."""

    credentials: str | None
    error: str | None
    token_account: dict | None = None


def try_refresh_oauth_credentials(credentials: str) -> RefreshOutcome:
    try:
        data = json.loads(credentials)
    except json.JSONDecodeError:
        return RefreshOutcome(None, "no_refresh_token")
    oauth = data.get("claudeAiOauth") if isinstance(data, dict) else None
    if not isinstance(oauth, dict) or not oauth.get("refreshToken"):
        return RefreshOutcome(None, "no_refresh_token")

    try:
        body = json.dumps({
            "grant_type": "refresh_token",
            "refresh_token": oauth["refreshToken"],
            "client_id": OAUTH_CLIENT_ID,
        }).encode()
        req = urllib.request.Request(
            OAUTH_TOKEN_URL,
            data=body,
            headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp_data = json.loads(resp.read().decode())

        now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        oauth["accessToken"] = resp_data["access_token"]
        oauth["expiresAt"] = now_ms + resp_data["expires_in"] * 1000
        if resp_data.get("refresh_token"):
            oauth["refreshToken"] = resp_data["refresh_token"]
        if resp_data.get("scope"):
            oauth["scopes"] = resp_data["scope"].split()

        data["claudeAiOauth"] = oauth
        return RefreshOutcome(json.dumps(data), None, _parse_token_account(resp_data))
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace") if hasattr(e, "read") else ""
        _logger.debug("OAuth refresh failed: %r, body: %s", e, body[:500])
        if e.code in (400, 401, 403) and (
            "invalid_grant" in body or "invalid_client" in body
        ):
            return RefreshOutcome(None, "invalid_grant")
        return RefreshOutcome(None, "transient")
    except Exception as e:
        _logger.debug("OAuth refresh failed: %r", e)
        return RefreshOutcome(None, "transient")


def _parse_token_account(resp_data: dict) -> dict | None:
    account = resp_data.get("account")
    if not isinstance(account, dict):
        return None
    uuid = account.get("uuid")
    if not isinstance(uuid, str) or not uuid.strip():
        return None
    email = account.get("email_address")
    organization = resp_data.get("organization")
    org_uuid = organization.get("uuid") if isinstance(organization, dict) else None
    return {
        "uuid": uuid.strip(),
        "email": email if isinstance(email, str) else None,
        "organizationUuid": org_uuid if isinstance(org_uuid, str) else None,
    }


def request_usage_data(access_token: str) -> dict:
    url = "https://api.anthropic.com/api/oauth/usage"
    headers = {
        "Authorization": f"Bearer {access_token}",
        "anthropic-beta": OAUTH_BETA_HEADER,
        "User-Agent": USER_AGENT,
    }
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode())


def build_usage_result(data: dict) -> dict:
    """Normalize the raw usage API payload into the flat shape Swift consumes,
    which becomes a row in Supabase's ``usage_current``. Returns {}, never None,
    when nothing parsed, so callers can always serialize the result."""
    result: dict = {}

    h5 = data.get("five_hour")
    if h5:
        entry = {"pct": h5["utilization"]}
        if h5.get("resets_at"):
            entry["resets_at"] = h5["resets_at"]
        result["five_hour"] = entry

    d7 = data.get("seven_day")
    if d7:
        entry = {"pct": d7["utilization"]}
        if d7.get("resets_at"):
            entry["resets_at"] = d7["resets_at"]
        result["seven_day"] = entry

    eu = data.get("extra_usage")
    if eu and eu.get("is_enabled"):
        used_credits = eu.get("used_credits")
        monthly_limit = eu.get("monthly_limit")
        utilization = eu.get("utilization")
        if used_credits is not None and monthly_limit is not None and utilization is not None:
            try:
                spend = {
                    "used": float(used_credits) / 100,
                    "limit": float(monthly_limit) / 100,
                    "pct": float(utilization),
                    "currency": eu.get("currency", "USD"),
                }
                if eu.get("resets_at"):
                    spend["resets_at"] = eu["resets_at"]
                result["spend"] = spend
            except (TypeError, ValueError) as e:
                _logger.debug("extra_usage parse failed: %r", e)

    limits = data.get("limits")
    if isinstance(limits, list):
        scoped: list[dict] = []
        for lim in limits:
            if not isinstance(lim, dict):
                continue
            scope = lim.get("scope")
            model = scope.get("model") if isinstance(scope, dict) else None
            name = model.get("display_name") if isinstance(model, dict) else None
            pct = lim.get("percent")
            if not name or not isinstance(pct, (int, float)):
                continue
            entry = {"name": name, "pct": float(pct)}
            if lim.get("resets_at"):
                entry["resets_at"] = lim["resets_at"]
            scoped.append(entry)
        if scoped:
            result["scoped"] = scoped

    return result
