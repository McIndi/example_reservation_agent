"""Import-and-construct check, run in CI against the built image.

This tool's breakage was FastMCP being renamed to MCPServer. Importing
server registers all seven tools through the decorator API, so a moved API
fails here at build time rather than at MCP Gateway registration, where it
surfaces as a tool that will not go Ready for reasons that look like
credentials.

The name set is also a contract: the gateway registration and the agent's
TOOLS list both expect exactly these.

Run: python -m src.smoketest
"""
from __future__ import annotations

import asyncio

from .server import mcp

EXPECTED_TOOLS = {
    "get_business_hours",
    "check_availability",
    "suggest_reservation_times",
    "book_reservation",
    "get_reservation",
    "cancel_reservation",
    "reschedule_reservation",
}


async def main() -> None:
    names = {tool.name for tool in await mcp.list_tools()}
    missing = EXPECTED_TOOLS - names
    if missing:
        raise SystemExit(f"tool smoke test failed, missing: {sorted(missing)}")
    print(f"tool smoke test passed: {len(names)} tools registered")


if __name__ == "__main__":
    asyncio.run(main())
