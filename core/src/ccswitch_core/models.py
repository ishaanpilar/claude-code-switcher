"""Small shared types.

``Platform`` is kept even though this build only implements the MACOS branch:
every call site that will need a Windows or Linux implementation later already
switches on it, so expansion stays additive.
"""

from __future__ import annotations

import enum
import platform as _platform
from datetime import datetime, timezone


class Platform(enum.Enum):
    MACOS = "macos"
    WINDOWS = "windows"
    LINUX = "linux"
    UNKNOWN = "unknown"

    @staticmethod
    def detect() -> "Platform":
        system = _platform.system()
        if system == "Darwin":
            return Platform.MACOS
        if system == "Windows":
            return Platform.WINDOWS
        if system == "Linux":
            return Platform.LINUX
        return Platform.UNKNOWN


def get_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
