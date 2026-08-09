"""Deployed graphs for all yaml-flagged async sub-agents.

One lazy factory binding per ``async: true`` entry in
``EvoScientist/subagents/<name>.yaml``. Each factory builds the graph via
``build_async_subagent_graph`` (which reads the yaml, wires tools/skills/
backend/middleware identical to the in-process sync version, and returns a
runnable langgraph), caches the result, and applies the same private-state
filter used by the main graph.

To add a new async sub-agent:

  1. Set ``async: true`` in ``EvoScientist/subagents/<name>.yaml``.
  2. Add a lazy factory binding for the new agent, following the pattern below.

  3. Register it in ``EvoScientist/langgraph_dev/langgraph.json``::

         "<name>": "EvoScientist.langgraph_dev.graphs:<snake_name>"

The deployed main agent (``EvoScientist_agent``) lives in ``main_graph.py``
as a lazy factory so neither the main agent nor these sub-agents are built
just to make the langgraph dev server reachable.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Any


def _filtered(graph: Any) -> Any:
    """Apply EvoScientist's private-state filter to a built graph."""
    from .main_graph import _apply_filter_to_graph

    return _apply_filter_to_graph(graph)


@lru_cache(maxsize=1)
def writing_agent() -> Any:
    from EvoScientist.subagents._factory import build_async_subagent_graph

    return _filtered(build_async_subagent_graph("writing-agent"))


@lru_cache(maxsize=1)
def data_analysis_agent() -> Any:
    from EvoScientist.subagents._factory import build_async_subagent_graph

    return _filtered(build_async_subagent_graph("data-analysis-agent"))


@lru_cache(maxsize=1)
def scheduler() -> Any:
    from EvoScientist.subagents._factory import build_async_subagent_graph

    return _filtered(build_async_subagent_graph("scheduler"))


@lru_cache(maxsize=1)
def expert_container_async() -> Any:
    from EvoScientist.subagents.expert_container_async import (
        build_expert_container_async_graph,
    )

    return _filtered(build_expert_container_async_graph())


@lru_cache(maxsize=1)
def evomemory_subagent_worker() -> Any:
    from EvoScientist.memory.agents.memory_worker import build_memory_worker_graph
    from EvoScientist.memory.types import MemorySourceType

    return _filtered(build_memory_worker_graph(MemorySourceType.SUBAGENT))


@lru_cache(maxsize=1)
def evomemory_turn_worker() -> Any:
    from EvoScientist.memory.agents.memory_worker import build_memory_worker_graph
    from EvoScientist.memory.types import MemorySourceType

    return _filtered(build_memory_worker_graph(MemorySourceType.TURN))


@lru_cache(maxsize=1)
def evomemory_observation_linker() -> Any:
    from EvoScientist.memory.agents.observation_linker import (
        build_observation_linker_graph,
    )

    return _filtered(build_observation_linker_graph())


@lru_cache(maxsize=1)
def evomemory_autoskills() -> Any:
    from EvoScientist.memory.agents.autoskills import build_autoskills_graph

    return _filtered(build_autoskills_graph())
