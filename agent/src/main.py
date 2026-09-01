"""Entry point: serves the reservation agent over A2A."""
from __future__ import annotations

import os

import uvicorn
from a2a.server.apps import A2AStarletteApplication
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentSkill

from .agent_executor import ReservationAgentExecutor

PORT = int(os.environ.get("PORT", "8000"))
AGENT_URL = os.environ.get("AGENT_URL", f"http://reservation-agent:{PORT}/")


def build_agent_card() -> AgentCard:
    skill = AgentSkill(
        id="book_reservation",
        name="Book a reservation",
        description=(
            "Suggests open 30-minute reservation slots, Monday-Friday "
            "09:00-17:00, and books, cancels, or reschedules a "
            "reservation once the customer agrees on a time."
        ),
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
        url=AGENT_URL,
        version="0.1.0",
        default_input_modes=["text"],
        default_output_modes=["text"],
        capabilities=AgentCapabilities(streaming=False),
        skills=[skill],
    )


def build_app() -> A2AStarletteApplication:
    handler = DefaultRequestHandler(
        agent_executor=ReservationAgentExecutor(),
        task_store=InMemoryTaskStore(),
    )
    return A2AStarletteApplication(agent_card=build_agent_card(), http_handler=handler)


app = build_app().build()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
