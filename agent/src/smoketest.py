"""Import-and-construct check, run in CI against the built image.

Every breakage this repo has had came from an unpinned dependency moving
under it: FastMCP renamed to MCPServer, A2AStarletteApplication removed,
Client losing its http_client argument. None of them needed a network call
to catch, only an import and a constructor, and all three shipped because
nothing here ever ran the code before publishing the image.

Dependencies are deliberately unpinned so the images track current
releases. This is what stands between a moved API and a deployed agent
that cannot call a tool.

Run: python -m src.smoketest
"""
from __future__ import annotations

from mcp import Client

from .agent import ReservationAgent
from .main import build_app
from .mcp_client import MCP_TIMEOUT_SECONDS


def main() -> None:
    app = build_app()
    if not app.routes:
        raise SystemExit("agent app built with no routes")

    # Exercises AsyncOpenAI's constructor, including timeout and max_retries.
    ReservationAgent()

    # Constructed, never connected. This is the call that broke silently when
    # mcp 2.x dropped http_client, and it now fails at build time instead.
    Client("http://smoketest.invalid/mcp", read_timeout_seconds=MCP_TIMEOUT_SECONDS)

    print(f"agent smoke test passed: {len(app.routes)} routes")


if __name__ == "__main__":
    main()
