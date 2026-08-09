"""Minimal launcher used by ``./evosci.sh`` for WebUI mode.

It starts the same backend + local WebUI as ``EvoSci --ui webui`` without
importing the full CLI command tree, which shaves several seconds off
restart/start.
"""

from __future__ import annotations

import os

from ..config import load_config
from .webui import run_webui


def main() -> None:
    """Load config and start WebUI mode."""
    run_webui(load_config(), workspace_dir=os.environ.get("EVOSCIENTIST_WORKSPACE_DIR"))


if __name__ == "__main__":
    main()
