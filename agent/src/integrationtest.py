"""Drive the real tool over MCP and check the whole reservation contract.

The smoke test proves the code imports and constructs. This proves it works:
it books a slot, reads it back, confirms availability changed, cancels it, and
checks that a refusal comes back fast with the tool's own message. Bugs that
only exist in the call path live here, and several have.

Reads MCP_URL and MCP_TOOL_PREFIX the same way the agent does, so the same
command works against a tool Service, against MCP Gateway with
MCP_TOOL_PREFIX=reservation_, or from inside a deployed pod:

    oc exec -n team1 deploy/reservation-agent -- python -m src.integrationtest

It books and then cancels one real reservation, so do not point it at
something you would mind that happening to.
"""
from __future__ import annotations

import asyncio
import os
import socket
import sys
import time
from urllib.parse import urlparse

from . import mcp_client

MCP_URL = os.environ.get("MCP_URL", "http://127.0.0.1:8000/mcp")
MCP_TOOL_PREFIX = os.environ.get("MCP_TOOL_PREFIX", "")
WAIT_SECONDS = float(os.environ.get("WAIT_SECONDS", "60"))

failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail else ''}")
    if not ok:
        failures.append(name)


async def call(name: str, arguments: dict) -> object:
    return await mcp_client.call_tool(MCP_URL, MCP_TOOL_PREFIX + name, arguments)


def wait_for_endpoint() -> None:
    """Block until the MCP host accepts connections, or give up."""
    parsed = urlparse(MCP_URL)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        with socket.socket() as probe:
            probe.settimeout(1.0)
            if probe.connect_ex((host, port)) == 0:
                return
        time.sleep(0.5)
    raise SystemExit(f"nothing listening on {host}:{port} after {WAIT_SECONDS}s")


async def run() -> None:
    hours = await call("get_business_hours", {})
    check("get_business_hours returns an object", isinstance(hours, dict), repr(hours)[:90])
    check(
        "business hours are what the tool enforces",
        isinstance(hours, dict) and hours.get("open") == "09:00" and hours.get("close") == "17:00",
        repr(hours)[:90],
    )

    # A list return arrives as one content block per element. Asking for three
    # and getting one back is the shape of a truncation bug, so assert the count.
    slots = await call("suggest_reservation_times", {"count": 3})
    check("suggest_reservation_times returns three", isinstance(slots, list) and len(slots) == 3, repr(slots)[:110])
    if not (isinstance(slots, list) and slots):
        raise SystemExit("cannot continue without a suggested slot")

    first = slots[0]
    booking = await call(
        "book_reservation",
        {"customer_name": "Integration Test", "date": first["date"], "time": first["time"]},
    )
    check("book_reservation returns an id", bool(booking.get("id")), repr(booking)[:90])

    fetched = await call("get_reservation", {"reservation_id": booking["id"]})
    check("the booking reads back", fetched.get("id") == booking["id"], repr(fetched)[:90])

    free = await call("check_availability", {"date": first["date"]})
    check("check_availability returns a list", isinstance(free, list), repr(free)[:90])
    check(
        "the booked slot is no longer offered",
        isinstance(free, list) and first["time"] not in free,
        f"booked {first['time']}, free: {str(free)[:70]}",
    )

    await call("cancel_reservation", {"reservation_id": booking["id"]})
    freed = await call("check_availability", {"date": first["date"]})
    check(
        "cancelling puts the slot back",
        isinstance(freed, list) and first["time"] in freed,
        f"{first['time']} in {str(freed)[:70]}",
    )

    # A refusal has to arrive as ToolCallFailed with the tool's own text, and
    # fast. A tool that signals failure the wrong way stalls until the read
    # timeout instead, which is indistinguishable from an outage.
    started = time.monotonic()
    try:
        await call("get_reservation", {"reservation_id": "no-such-id"})
        check("an unknown id is refused", False, "no exception raised")
    except mcp_client.ToolCallFailed as exc:
        elapsed = time.monotonic() - started
        check("an unknown id is refused", True, f"{elapsed:.2f}s")
        check("the refusal carries the tool's message", "no-such-id" in str(exc), str(exc)[:80])
        check("the refusal is fast, not a timeout", elapsed < 5, f"{elapsed:.2f}s")
    except Exception as exc:  # noqa: BLE001 - the type is the finding
        check("an unknown id is refused", False, f"got {type(exc).__name__}: {exc}"[:110])


def main() -> None:
    print(f"MCP_URL={MCP_URL}  MCP_TOOL_PREFIX={MCP_TOOL_PREFIX!r}")
    wait_for_endpoint()
    asyncio.run(run())
    print()
    if failures:
        print(f"{len(failures)} failure(s): {', '.join(failures)}")
        sys.exit(1)
    print("integration test passed")


if __name__ == "__main__":
    main()
