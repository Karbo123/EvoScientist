"""EvoScientist deploy mode.

Standalone LangGraph server launcher. ``EvoSci deploy`` starts a
``langgraph dev`` subprocess hosting the fully-equipped main agent
(MCP + async sub-agents enabled), exposed at
``http://localhost:{port}`` for external LangChain-compatible UIs
and SDK clients.

This module is intentionally separate from ``EvoScientist.cli``:
deploy mode does NOT load an in-process CLI agent, session DB, channel
runtime, or TUI — those are all TUI / serve concerns. Deploy only
manages the lifecycle of the langgraph dev subprocess (and ccproxy if
OAuth is configured).

``server`` is imported lazily so the WebUI launcher can avoid pulling in
the full CLI command tree during startup.
"""

from __future__ import annotations

from importlib import import_module

__all__ = ["server"]


def __getattr__(name: str):
    if name == "server":
        return import_module(f"{__name__}.server")
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
