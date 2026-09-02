"""Minimal MCP client: calls one tool on the reservation MCP server and
returns its result as plain Python data.

Uses the mcp>=2.0 API: streamablehttp_client + ClientSession were
replaced by a single Client. A tool that reports a business failure comes
back as a normal result with is_error set, not as a raised exception, so
the caller has to check for it. MCPError is reserved for protocol-level
failures. See
https://py.sdk.modelcontextprotocol.io/migration/ if this drifts again.

Opens a fresh Client per call. That is not the most efficient pattern,
but it keeps this example agent simple and avoids holding a session open
across the LLM's think time.

The client-side deadline is Client(read_timeout_seconds=...), a float.
This version takes no http_client argument, so there is no custom httpx
client to inject a timeout through - verified against mcp 2.1.1.
"""
from __future__ import annotations

import json
import os
from typing import Any

from mcp import Client, MCPError

# How long to wait for one tool result. The call goes through MCP Gateway,
# AuthBridge, and IBAC before it reaches the tool, so it needs more room than a
# direct call would, and the SDK leaves this unset by default, which gives a
# wedged gateway no deadline at all.
MCP_TIMEOUT_SECONDS = float(os.environ.get("MCP_TIMEOUT_SECONDS", "30"))


class ToolCallFailed(RuntimeError):
    """The tool ran and reported a failure.

    Kept distinct from a transport, auth, or gateway failure because the
    two need opposite handling. Here the tool answered ("that slot is
    taken", "no reservation with that id") and the model has something
    real to relay. A transport failure is no answer at all, and handing
    that to a model invites an invented one. agent.py relies on the
    difference.
    """


async def call_tool(mcp_url: str, name: str, arguments: dict[str, Any]) -> Any:
    # Client.__aenter__ performs the handshake itself, so there is no separate
    # initialize() step. Calling one raises AttributeError inside the session's
    # task group, which surfaces as an opaque ExceptionGroup.
    async with Client(mcp_url, read_timeout_seconds=MCP_TIMEOUT_SECONDS) as client:
        try:
            result = await client.call_tool(name, arguments)
        except MCPError as exc:
            raise RuntimeError(str(exc)) from exc

    if getattr(result, "is_error", False):
        raise ToolCallFailed(_error_text(result))
    return _unpack(result)


def _error_text(result: Any) -> str:
    """Join the text the tool sent back with its failure."""
    parts = [b.text for b in result.content if hasattr(b, "text")]
    return " ".join(parts) if parts else "the tool reported a failure"


def _unpack(result: Any) -> Any:
    """Turn a CallToolResult back into what the tool function returned.

    A tool that returns a list arrives as one content block per element, so
    reading only the first block silently truncates it. check_availability
    reported one free slot out of sixteen that way, and
    suggest_reservation_times offered one option when the agent is told to
    offer three.

    structured_content carries the whole value when the server sends it, with
    a non-object return wrapped under a sole "result" key. MCP Gateway is not
    guaranteed to forward it, so the content blocks remain a fallback.
    """
    structured = getattr(result, "structured_content", None)
    if structured is not None:
        if isinstance(structured, dict) and set(structured) == {"result"}:
            return structured["result"]
        return structured

    values = [_parse(b.text) for b in result.content if hasattr(b, "text")]
    if not values:
        return None
    return values[0] if len(values) == 1 else values


def _parse(text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text
