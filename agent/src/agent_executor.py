"""Wires ReservationAgent into the A2A protocol.

Modeled on the a2a-sdk quickstart shape (the same one the platform's own
LangGraph a2a-currency-agent example uses - see
docs/concepts/tech-details.md in the rossoctl repo). If a2a-sdk's API has
moved since this was written, check that project's samples for the
current AgentExecutor / TaskUpdater signatures.
"""
from __future__ import annotations

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.types import Part, TextPart
from a2a.utils import new_task

from .agent import ReservationAgent


class ReservationAgentExecutor(AgentExecutor):
    def __init__(self) -> None:
        self._agent = ReservationAgent()

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        task = context.current_task
        if not task:
            task = new_task(context.message)
            await event_queue.enqueue_event(task)

        updater = TaskUpdater(event_queue, task.id, task.context_id)
        reply = await self._agent.invoke(context.get_user_input(), task.context_id)
        await updater.add_artifact([Part(root=TextPart(text=reply))])
        await updater.complete()

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("cancel is not supported by this example agent")
