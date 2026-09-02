"""Minimal MCP client: calls one tool on the reservation MCP server and
returns its result as plain Python data.

Uses the mcp>=2.0 API: streamablehttp_client + ClientSession were
replaced by a single Client, which raises MCPError on a tool failure
instead of returning an isError=True result. See
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


async def call_tool(mcp_url: str, name: str, arguments: dict[str, Any]) -> Any:
    async with Client(mcp_url, read_timeout_seconds=MCP_TIMEOUT_SECONDS) as client:
        await client.initialize()
        try:
            result = await client.call_tool(name, arguments)
        except MCPError as exc:
            raise RuntimeError(str(exc)) from exc

    for block in result.content:
        if hasattr(block, "text"):
            try:
                return json.loads(block.text)
            except json.JSONDecodeError:
                return block.text
    return None
