"""Conversation engine for the reservation agent.

Reads LLM_API_BASE / LLM_MODEL / LLM_API_KEY the same way every other
Rossoctl example agent does (see
docs/how-to-guides/point-rossoctl-agents-at-a-provider.md in this repo),
and calls the reservation MCP tool at MCP_URL for every availability,
booking, cancellation, or reschedule question - the model never invents
a slot or reservation id on its own.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from collections.abc import Awaitable, Callable
from datetime import date

from openai import AsyncOpenAI

from . import mcp_client

MCP_URL = os.environ.get("MCP_URL", "http://reservation-tool-mcp:8000/mcp")

# One LLM call has to finish inside the caller's gap budget. Rossoctl's chat
# proxy allows 120s between SSE events, and OpenShift's router cuts an idle
# connection sooner than that by default, so a call that runs longer than this
# should fail cleanly instead of hanging. openai-python's own defaults are 600s
# with 2 retries, which turns one slow call into a 30-minute stall.
LLM_TIMEOUT_SECONDS = float(os.environ.get("LLM_TIMEOUT_SECONDS", "90"))

# How often to re-emit a status line while one step is in flight. The caller's
# timeout applies to the gap between SSE events, so a beat well under the
# tightest ceiling in the path keeps a slow round alive however long inference
# takes. OpenShift's router is the tightest one at 30s of inactivity by
# default, which is why this is not simply set to a minute.
HEARTBEAT_SECONDS = float(os.environ.get("HEARTBEAT_SECONDS", "10"))

SYSTEM_PROMPT_TEMPLATE = """You are a scheduling assistant. You book 30-minute
reservations, Monday-Friday, 09:00-17:00. Today's date is {today}.

Rules:
- Never state or assume an available slot, a reservation id, or a
  business-hours rule yourself. Always call a tool to check or change
  real availability and reservations.
- When a customer wants to book and has not named a date/time, call
  suggest_reservation_times and offer exactly three concrete
  date/time options in your reply. Ask which one works, or whether
  they would like other options.
- If the customer names a date/time, call check_availability for that
  date. If it is free, confirm it back to them before booking. If it
  is taken, call suggest_reservation_times starting from that date and
  offer three alternatives.
- Only call book_reservation after the customer has clearly agreed to
  one specific date and time.
- For a cancellation or reschedule, get the reservation id from the
  customer (ask for it, or their name, if they do not give one), then
  call cancel_reservation or reschedule_reservation.
- After a successful tool call, confirm what happened in plain
  language: the date, time, and reservation id.
- Keep replies short and concrete.
"""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "suggest_reservation_times",
            "description": "Suggest the next open 30-minute reservation slots.",
            "parameters": {
                "type": "object",
                "properties": {
                    "count": {"type": "integer", "default": 3},
                    "earliest_date": {"type": "string", "description": "YYYY-MM-DD"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "check_availability",
            "description": "List open 30-minute slots for one date.",
            "parameters": {
                "type": "object",
                "properties": {"date": {"type": "string", "description": "YYYY-MM-DD"}},
                "required": ["date"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "book_reservation",
            "description": "Book a 30-minute reservation at an agreed date and time.",
            "parameters": {
                "type": "object",
                "properties": {
                    "customer_name": {"type": "string"},
                    "date": {"type": "string", "description": "YYYY-MM-DD"},
                    "time": {"type": "string", "description": "HH:MM"},
                },
                "required": ["customer_name", "date", "time"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_reservation",
            "description": "Look up one reservation by id.",
            "parameters": {
                "type": "object",
                "properties": {"reservation_id": {"type": "string"}},
                "required": ["reservation_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "cancel_reservation",
            "description": "Cancel an existing reservation.",
            "parameters": {
                "type": "object",
                "properties": {"reservation_id": {"type": "string"}},
                "required": ["reservation_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "reschedule_reservation",
            "description": "Move an existing reservation to a new date and time.",
            "parameters": {
                "type": "object",
                "properties": {
                    "reservation_id": {"type": "string"},
                    "new_date": {"type": "string", "description": "YYYY-MM-DD"},
                    "new_time": {"type": "string", "description": "HH:MM"},
                },
                "required": ["reservation_id", "new_date", "new_time"],
            },
        },
    },
]

MAX_TOOL_ROUNDS = 4

# Every round re-sends the whole history, so an unbounded history makes each
# turn slower than the last. That bites hardest on CPU-only inference, where
# prompt evaluation is not free.
MAX_HISTORY_MESSAGES = 24

# Shown to the customer while a tool call is in flight. On a slow model this is
# the only thing they see for tens of seconds, so name the actual step.
TOOL_PROGRESS = {
    "suggest_reservation_times": "Looking for open times...",
    "check_availability": "Checking that date...",
    "book_reservation": "Booking that slot...",
    "get_reservation": "Looking up that reservation...",
    "cancel_reservation": "Cancelling that reservation...",
    "reschedule_reservation": "Moving that reservation...",
}

# Called with a short status line at each step of a turn. agent_executor passes
# one that pushes an A2A status update, which reaches the UI as its own SSE
# event and keeps the connection from going quiet.
ProgressCallback = Callable[[str], Awaitable[None]]

# What the customer sees when a tool call could not be completed. Saying that
# nothing was booked matters: the failure modes here are auth and network, and
# a customer left unsure whether a booking landed is worse off than one told
# plainly that it did not.
TOOL_FAILURE_REPLY = (
    "I couldn't reach the scheduling system just now, so I don't have a real "
    "answer for you. Nothing has been booked or changed. Please try again in a "
    "moment."
)

logger = logging.getLogger(__name__)


class ReservationAgent:
    """Holds one chat client and a per-conversation message history."""

    def __init__(self) -> None:
        self._client = AsyncOpenAI(
            base_url=os.environ["LLM_API_BASE"],
            api_key=os.environ.get("LLM_API_KEY", "unused"),
            timeout=LLM_TIMEOUT_SECONDS,
            max_retries=0,
        )
        self._model = os.environ["LLM_MODEL"]
        self._histories: dict[str, list[dict]] = {}

    def _history(self, context_id: str) -> list[dict]:
        if context_id not in self._histories:
            self._histories[context_id] = [
                {
                    "role": "system",
                    "content": SYSTEM_PROMPT_TEMPLATE.format(today=date.today().isoformat()),
                }
            ]
        return self._histories[context_id]

    def _trim(self, history: list[dict]) -> None:
        """Drop the oldest exchanges, keeping the system prompt.

        Cuts back to the next user message, so a tool result never ends up
        first in the window without the assistant message that asked for it.
        The completions API rejects that pairing.
        """
        if len(history) <= MAX_HISTORY_MESSAGES:
            return
        keep = history[-MAX_HISTORY_MESSAGES:]
        while keep and keep[0].get("role") != "user":
            keep.pop(0)
        history[1:] = keep

    async def _with_heartbeat(
        self,
        awaitable,
        on_progress: ProgressCallback | None,
        label: str,
    ):
        """Run one step, re-emitting a status line while it is in flight.

        Per-round updates alone bound the gap between events to one LLM
        call, which is still long enough to trip a 30s router timeout on
        CPU inference. A beat bounds it to HEARTBEAT_SECONDS instead, and
        needs no cluster-side setting that a later reinstall could drop.

        The elapsed count keeps consecutive beats distinct rather than
        repeating one phrase, and doubles as a progress signal on a model
        slow enough to need this in the first place.
        """
        if on_progress is None:
            return await awaitable
        task = asyncio.ensure_future(awaitable)
        started = time.monotonic()
        try:
            while True:
                done, _ = await asyncio.wait({task}, timeout=HEARTBEAT_SECONDS)
                if done:
                    return task.result()
                await on_progress(f"{label} ({int(time.monotonic() - started)}s)...")
        finally:
            if not task.done():
                task.cancel()

    async def invoke(
        self,
        user_text: str,
        context_id: str,
        on_progress: ProgressCallback | None = None,
    ) -> str:
        history = self._history(context_id)
        self._trim(history)
        checkpoint = len(history)
        history.append({"role": "user", "content": user_text})

        for _ in range(MAX_TOOL_ROUNDS):
            if on_progress:
                await on_progress("Thinking...")
            response = await self._with_heartbeat(
                self._client.chat.completions.create(
                    model=self._model,
                    messages=history,
                    tools=TOOLS,
                ),
                on_progress,
                "Still thinking",
            )
            message = response.choices[0].message
            history.append(message.model_dump(exclude_none=True))

            if not message.tool_calls:
                return message.content or ""

            tool_failure: Exception | None = None
            for tool_call in message.tool_calls:
                if on_progress:
                    await on_progress(
                        TOOL_PROGRESS.get(tool_call.function.name, "Working on that...")
                    )
                arguments = json.loads(tool_call.function.arguments or "{}")
                try:
                    result = await self._with_heartbeat(
                        mcp_client.call_tool(
                            MCP_URL, tool_call.function.name, arguments
                        ),
                        on_progress,
                        "Still working",
                    )
                    content = json.dumps(result)
                except Exception as exc:
                    # An exception here is an infrastructure failure - auth,
                    # network, the gateway - never a business answer, because
                    # "no slots that day" comes back as a successful result.
                    # Handing it to the model invites a confident, invented
                    # reply, so record it and end the turn instead.
                    logger.warning(
                        "tool call %s failed: %s", tool_call.function.name, exc
                    )
                    tool_failure = exc
                    content = json.dumps({"error": str(exc)})
                history.append(
                    {
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "content": content,
                    }
                )

            if tool_failure is not None:
                # Roll the turn back rather than leave the failed exchange in
                # history. A later turn that can see it will build on it, which
                # is how a dead credential turns into a confidently invented
                # booking confirmation.
                del history[checkpoint:]
                return TOOL_FAILURE_REPLY

        return (
            "I'm having trouble finishing that through the scheduling tool right "
            "now. Could you try again in a moment?"
        )
