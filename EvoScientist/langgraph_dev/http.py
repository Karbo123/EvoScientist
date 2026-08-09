"""Custom HTTP routes mounted alongside the langgraph dev server.

The langgraph-api host supports a top-level ``http`` key in
``langgraph.json`` that names an ASGI app to mount on the same
process as the graph. We use it to surface the registry the WebUI's
``/model`` picker needs.

Why this lives here and not as a separate sidecar: the WebUI talks to
``EvoSci deploy``'s langgraph endpoint anyway, so one origin keeps the
WebUI's fetch logic simple — no CORS dance, no extra port to configure.

Why Starlette and not FastAPI: ``langgraph_api`` already depends on
Starlette; adding FastAPI would pull in pydantic v1-vs-v2 reconciliation
the deploy doesn't need. The one route here has no input model, just a
JSON body, so the lower-level surface is sufficient.

Lightweight by design — module-level imports stick to ``config``,
``llm.models`` (registry only; no chat-model construction), and
Starlette itself. Nothing on this surface should pull the agent into
memory.
"""

from __future__ import annotations

import asyncio
import json

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from EvoScientist.config import get_effective_config
from EvoScientist.llm.models import list_model_picker_entries


async def get_models(_request: Request) -> JSONResponse:
    """Return the model registry as ``{entries, default}``.

    ``entries`` preserves the registry order so the WebUI picker can
    rank providers per short name the same way the backend would.
    Mirrors the TUI ``/model`` picker by appending locally-pulled
    Ollama models when ``ollama_base_url`` is configured — same
    ``discover_ollama_models()`` call, same 1.5-s timeout, same
    fail-soft semantics (the probe returns ``[]`` on any error, never
    raises). The TUI's "Custom Ollama model…" sentinel is intentionally
    omitted — that's a widget-specific input affordance, not part of
    the registry surface.

    ``default`` reflects the deployment's currently-configured fallback
    (``config.yaml``'s ``model`` / ``provider`` — what ``/model reset``
    would land on). Returned even when the configured pair isn't in
    the registry, so the picker can still label it.

    Uses ``get_effective_config()`` (not ``load_config()``) so env-var
    overrides like ``OLLAMA_BASE_URL`` from ``_ENV_MAPPINGS`` are
    honored — matching the deploy's actual model-building behavior.
    Offloaded to a thread because ``get_effective_config()`` calls
    ``find_dotenv(usecwd=True)`` which invokes ``os.getcwd()`` — a
    blocking syscall that langgraph-dev's ``blockbuster`` middleware
    refuses to allow on the async event loop (would surface as a 500).
    """
    cfg = await asyncio.to_thread(get_effective_config)
    entries = [
        {"name": name, "model_id": model_id, "provider": provider}
        for name, model_id, provider in await list_model_picker_entries(
            getattr(cfg, "ollama_base_url", None),
            include_custom_ollama=False,
        )
    ]
    return JSONResponse(
        {
            "entries": entries,
            "default": {"name": cfg.model, "provider": cfg.provider},
        }
    )


async def get_commands(_request: Request) -> JSONResponse:
    """Return the registered slash-command catalog for WebUI autocomplete.

    Kept lazy so this route doesn't pull the command implementation modules
    into the startup path; only the first ``/api/commands`` request pays for it.
    """

    def _load_commands() -> list[dict[str, str]]:
        from EvoScientist.commands import manager

        return [
            {"name": name, "description": description}
            for name, description in manager.list_commands()
        ]

    return JSONResponse(await asyncio.to_thread(_load_commands))


async def get_teams(_request: Request) -> JSONResponse:
    """Return installed expert skills as ``{teams: [...]}`` for the WebUI gallery.

    A "team" in the WebUI vocabulary is an installed expert skill — a skill
    directory carrying a sibling ``AGENTS.md`` (or, on the deprecated path,
    ``type: expert`` SKILL.md frontmatter). The response is a curated,
    gallery-safe projection: name + description, plus optional ``byline`` /
    ``capability_tags`` / ``avatar_hint`` when the skill populates them.

    Cards for experts on the current contract carry name + description only:
    the decoration fields were actor metadata in SKILL.md frontmatter, which
    that contract removes rather than relocates (``AGENTS.md`` has no
    frontmatter to hold them). The omit-when-unpopulated projection below is
    what makes those cards degrade rather than break; restoring richer cards
    means sourcing decoration from index metadata, not re-adding frontmatter
    fields.

    Backend implementation details (SKILL.md body / system prompt, role
    line, tool list, source tier, filesystem path,
    tags) are intentionally NOT projected. The gallery only needs
    identity + descriptor fields to render the card; anything richer
    belongs in a dedicated info endpoint.

    Sourced from ``list_expert_skills(include_system=True)`` so
    first-party experts shipped as builtin skills surface alongside
    workspace/global installs.

    Offloaded to a thread because the skill loader does synchronous
    filesystem walking + yaml parsing, which langgraph-dev's
    ``blockbuster`` middleware refuses on the async event loop.

    Response shape (each entry): ``{name, description, byline?,
    capability_tags?, avatar_hint?}`` — the WebUI gallery consumes these.
    """
    from EvoScientist.tools.skills_manager import list_expert_skills

    experts = await asyncio.to_thread(list_expert_skills, True)
    teams = []
    for info in experts:
        entry = {
            "name": info.name,
            "description": info.description,
        }
        # Optional gallery fields — omit when unpopulated so the WebUI
        # card degrades gracefully (SkillInfo defaults `byline` /
        # `avatar_hint` to "" and `capability_tags` to [], which we
        # treat as "not declared").
        if info.byline:
            entry["byline"] = info.byline
        if info.capability_tags:
            entry["capability_tags"] = list(info.capability_tags)
        if info.avatar_hint:
            entry["avatar_hint"] = info.avatar_hint
        teams.append(entry)
    return JSONResponse({"teams": teams})


def _interrupt_payload(value: object) -> object:
    """Convert LangGraph ``Interrupt`` tuples into JSON-friendly objects."""
    if not isinstance(value, list):
        return value
    result = []
    for item in value:
        if item is None or isinstance(item, dict):
            result.append(item)
        else:
            result.append(
                {
                    "value": getattr(item, "value", None),
                    "id": getattr(item, "id", None),
                }
            )
    return result


async def _latest_thread_values(thread_id: str, db_path: str | None = None) -> dict:
    """Return the non-message state values stored in the latest checkpoint."""
    from EvoScientist.sessions import (
        MAIN_THREAD_FILTER_PARAMS,
        MAIN_THREAD_FILTER_SQL,
        _table_exists,
        get_db_path,
    )

    try:
        import aiosqlite
        from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer

        db_path = db_path or str(get_db_path())
        async with aiosqlite.connect(db_path, timeout=30.0) as conn:
            if not await _table_exists(conn, "checkpoints"):
                return {}
            query = (
                "SELECT checkpoint_id, type, checkpoint FROM checkpoints "
                "WHERE thread_id = ? AND checkpoint_ns = '' "
                f"  AND {MAIN_THREAD_FILTER_SQL} "
                "ORDER BY checkpoint_id DESC LIMIT 1"
            )
            async with conn.execute(
                query, (thread_id, *MAIN_THREAD_FILTER_PARAMS)
            ) as cur:
                row = await cur.fetchone()
            if row is None or row[0] is None or row[1] is None:
                return {}
            checkpoint = JsonPlusSerializer().loads_typed((row[1], row[2]))
            values = checkpoint.get("channel_values") or {}
            result = {
                key: values[key]
                for key in (
                    "todos",
                    "files",
                    "async_tasks",
                    "email",
                    "ui",
                    "_summarization_event",
                    "__interrupt__",
                )
                if key in values
            }
            if "__interrupt__" in result:
                result["__interrupt__"] = _interrupt_payload(result["__interrupt__"])
            else:
                async with conn.execute(
                    "SELECT type, value FROM writes "
                    "WHERE thread_id = ? AND checkpoint_ns = '' "
                    "  AND checkpoint_id = ? AND channel = '__interrupt__' "
                    "ORDER BY task_id, idx",
                    (thread_id, row[0]),
                ) as cur:
                    interrupt_rows = await cur.fetchall()
                if interrupt_rows:
                    interrupts = []
                    serde = JsonPlusSerializer()
                    for typ, blob in interrupt_rows:
                        if typ is None or blob is None:
                            continue
                        value = serde.loads_typed((typ, blob))
                        if isinstance(value, list):
                            interrupts.extend(value)
                        else:
                            interrupts.append(value)
                    result["__interrupt__"] = _interrupt_payload(interrupts)
            return result
    except Exception:
        return {}


async def get_thread_messages_page(request: Request) -> Response:
    """Return one page of a thread's messages read directly from SQLite."""
    from EvoScientist.sessions import get_db_path, get_thread_messages

    thread_id = request.query_params.get("thread_id", "").strip()
    if not thread_id:
        return JSONResponse({"error": "thread_id is required"}, status_code=400)
    try:
        limit = int(request.query_params.get("limit", "100"))
    except ValueError:
        limit = 100
    limit = max(1, min(limit, 500))

    raw_offset = request.query_params.get("offset")
    try:
        offset = int(raw_offset) if raw_offset is not None else None
    except ValueError:
        offset = None

    # get_db_path() may mkdir the data dir; blockbuster forbids that syscall on
    # the async event loop, so resolve the path in a worker thread first.
    db_path = await asyncio.to_thread(lambda: str(get_db_path()))
    messages = await get_thread_messages(thread_id, db_path=db_path)
    total = len(messages)
    start = total - limit if offset is None else offset
    start = max(0, min(start, total))
    page = messages[start : start + limit]
    payload = {
        "messages": [message.model_dump() for message in page],
        "values": await _latest_thread_values(thread_id, db_path=db_path),
        "offset": start,
    }
    return Response(
        content=json.dumps(payload, ensure_ascii=False, default=str),
        media_type="application/json",
    )


app = Starlette(
    routes=[
        Route("/api/models", get_models, methods=["GET"]),
        Route("/api/commands", get_commands, methods=["GET"]),
        Route("/api/teams", get_teams, methods=["GET"]),
        Route("/api/threads/messages", get_thread_messages_page, methods=["GET"]),
    ]
)
