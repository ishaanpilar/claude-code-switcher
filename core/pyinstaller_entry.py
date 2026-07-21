"""PyInstaller entry point — a plain script (not ``-m ccswitch_core``) because PyInstaller
freezes a script file, not a module invocation. Just calls the same ``main()`` the CLI uses so the
frozen binary behaves identically to ``python -m ccswitch_core``.
"""

import sys

from ccswitch_core.__main__ import main

if __name__ == "__main__":
    sys.exit(main())
