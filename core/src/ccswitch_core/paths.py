"""Path resolution for Claude Code's own config/credential files, plus ours.

Mirrors Claude Code's own resolution so we read and write the same files it
does (ported from claude-swap's paths.py). Trimmed to macOS for this build —
Windows/Linux branches are additive later (BUILD_PLAN.md Phase 5), not a
rewrite: every call site here already takes the platform as a parameter shape
claude-swap's original used, we just dropped the XDG/Windows arms.
"""

from __future__ import annotations

import os
from pathlib import Path


def get_claude_config_home() -> Path:
    """Claude Code's own config home: ``CLAUDE_CONFIG_DIR`` or ``~/.claude``."""
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        return Path(env)
    return Path.home() / ".claude"


def get_global_config_path() -> Path:
    """Claude Code's global config file: legacy ``.config.json`` if present,
    else ``(CLAUDE_CONFIG_DIR || $HOME)/.claude.json``."""
    legacy = get_claude_config_home() / ".config.json"
    if legacy.exists():
        return legacy
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(env) if env else Path.home()
    return base / ".claude.json"


def get_credentials_path() -> Path:
    """Claude Code's plaintext credentials fallback file."""
    return get_claude_config_home() / ".credentials.json"


def get_core_data_root() -> Path:
    """Our own local data root — the per-account credential backup store and
    the local known-accounts index (store.py). Separate from Claude Code's
    own files above."""
    root = Path.home() / ".ccswitch"
    root.mkdir(parents=True, exist_ok=True)
    return root


def get_credentials_backup_dir() -> Path:
    d = get_core_data_root() / "credentials"
    d.mkdir(parents=True, exist_ok=True)
    return d
