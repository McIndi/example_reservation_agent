"""Entry point: serves the reservation agent over A2A.

Uses the a2a-sdk v1.0 app-wiring API: A2AStarletteApplication was
removed in favor of composing route factories directly into a Starlette
app (verified against
a2aproject/a2a-samples/samples/python/agents/helloworld/__main__.py).
"""
from __future__ import annotations

import os

import uvicorn
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill
from starlette.applications import Starlette

from .agent_executor import ReservationAgentExecutor

PORT = int(os.environ.get("PORT", "8000"))
# Rossoctl sets AGENT_ENDPOINT on every agent it deploys, to the Service
# address on port 8080. That is the address a client can reach; the container
# port is not, because the AuthBridge webhook moves it to 8001 and puts the
# sidecar's reverse proxy in front. Honor AGENT_ENDPOINT first so the agent
# card advertises the reachable one.
AGENT_URL = (
    os.environ.get("AGENT_ENDPOINT")
    or os.environ.get("AGENT_URL")
    or f"http://reservation-agent:{PORT}"
)


def build_agent_card() -> AgentCard:
    skill = AgentSkill(
        id="book_reservation",
        name="Book a reservation",
        description=(
            "Suggests open 30-minute reservation slots, Monday-Friday "
            "09:00-17:00, and books, cancels, or reschedules a "
            "reservation once the customer agrees on a time."
        ),
        input_modes=["text/plain"],
        output_modes=["text/plain"],
        tags=["scheduling", "reservations"],
        examples=[
            "I'd like to book a reservation this week",
            "Can you move my reservation to Thursday afternoon?",
            "Cancel reservation a1b2c3d4",
        ],
    )
    return AgentCard(
        name="Reservation Agent",
        description="Books, cancels, and reschedules 30-minute reservations.",
        version="0.1.0",
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        # Streaming matters more than it looks. Rossoctl's UI reads this flag
        # to choose between the backend's /send and /stream endpoints, and
        # /send waits for the whole reply as one blocking body under a 60s read
        # timeout. /stream applies its timeout between SSE events instead, so
        # the progress updates the executor emits per round keep the connection
        # alive through a slow tool-calling turn.
        capabilities=AgentCapabilities(streaming=True),
        supported_interfaces=[
            AgentInterface(
                protocol_binding="JSONRPC",
                url=AGENT_URL,
                protocol_version="1.0",
            )
        ],
        skills=[skill],
    )


def build_app() -> Starlette:
    agent_card = build_agent_card()
    request_handler = DefaultRequestHandler(
        agent_executor=ReservationAgentExecutor(),
        task_store=InMemoryTaskStore(),
        agent_card=agent_card,
    )
    routes = []
    routes.extend(create_agent_card_routes(agent_card))
    routes.extend(create_jsonrpc_routes(request_handler, "/", enable_v0_3_compat=True))
    return Starlette(routes=routes)


app = build_app()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
