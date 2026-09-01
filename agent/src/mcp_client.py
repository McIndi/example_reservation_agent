"""Minimal MCP client: calls one tool on the reservation MCP server and
returns its result as plain Python data.

Opens a fresh streamable-HTTP session per call. That is not the most
efficient pattern, but it keeps this example agent simple and avoids
holding a session open across the LLM's think time.
"""
from __future__ import annotations

import json
from typing import Any

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def call_tool(mcp_url: str, name: str, arguments: dict[str, Any]) -> Any:
    async with streamablehttp_client(mcp_url) as (read, write, _get_session_id):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments)

    if result.isError:
        message = "; ".join(
            block.text for block in result.content if hasattr(block, "text")
        )
        raise RuntimeError(message or "tool call failed")

    for block in result.content:
        if hasattr(block, "text"):
            try:
                return json.loads(block.text)
            except json.JSONDecodeError:
                return block.text
    return None
