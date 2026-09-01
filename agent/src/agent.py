"""Conversation engine for the reservation agent.

Reads LLM_API_BASE / LLM_MODEL / LLM_API_KEY the same way every other
Rossoctl example agent does (see
docs/how-to-guides/point-rossoctl-agents-at-a-provider.md in this repo),
and calls the reservation MCP tool at MCP_URL for every availability,
booking, cancellation, or reschedule question - the model never invents
a slot or reservation id on its own.
"""
from __future__ import annotations

import json
import os
from datetime import date

from openai import AsyncOpenAI

from . import mcp_client

MCP_URL = os.environ.get("MCP_URL", "http://reservation-tool-mcp:8000/mcp")

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


class ReservationAgent:
    """Holds one chat client and a per-conversation message history."""

    def __init__(self) -> None:
        self._client = AsyncOpenAI(
            base_url=os.environ["LLM_API_BASE"],
            api_key=os.environ.get("LLM_API_KEY", "unused"),
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

    async def invoke(self, user_text: str, context_id: str) -> str:
        history = self._history(context_id)
        history.append({"role": "user", "content": user_text})

        for _ in range(MAX_TOOL_ROUNDS):
            response = await self._client.chat.completions.create(
                model=self._model,
                messages=history,
                tools=TOOLS,
            )
            message = response.choices[0].message
            history.append(message.model_dump(exclude_none=True))

            if not message.tool_calls:
                return message.content or ""

            for tool_call in message.tool_calls:
                arguments = json.loads(tool_call.function.arguments or "{}")
                try:
                    result = await mcp_client.call_tool(
                        MCP_URL, tool_call.function.name, arguments
                    )
                    content = json.dumps(result)
                except Exception as exc:  # tool errors go back to the model, not the customer
                    content = json.dumps({"error": str(exc)})
                history.append(
                    {
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "content": content,
                    }
                )

        return (
            "I'm having trouble finishing that through the scheduling tool right "
            "now. Could you try again in a moment?"
        )
