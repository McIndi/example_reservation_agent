"""Wires ReservationAgent into the A2A protocol.

Matches the a2a-sdk v1.0 API (verified against
a2aproject/a2a-samples/samples/python/agents/helloworld/agent_executor.py):
task/status construction goes through the a2a.helpers functions, not
manually-built Part/TextPart objects, and TaskState uses the
TASK_STATE_* names. If a2a-sdk's API has moved again, compare this file
against that sample - it's the platform's own reference for this shape
(see docs/concepts/tech-details.md in the rossoctl repo).

The per-step status updates are load-bearing, not decoration: each one
reaches the client as its own SSE event, and the caller's timeout applies
to the gap between events rather than to the whole turn.
"""
from __future__ import annotations

from a2a.helpers import get_message_text, new_task_from_user_message, new_text_message, new_text_part
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.types import TaskState

from .agent import ReservationAgent


class ReservationAgentExecutor(AgentExecutor):
    def __init__(self) -> None:
        self._agent = ReservationAgent()

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        if context.current_task:
            task = context.current_task
        else:
            task = new_task_from_user_message(context.message)
            await event_queue.enqueue_event(task)

        updater = TaskUpdater(
            event_queue=event_queue, task_id=task.id, context_id=task.context_id
        )

        async def on_progress(text: str) -> None:
            await updater.update_status(
                state=TaskState.TASK_STATE_WORKING,
                message=new_text_message(text),
            )

        query = get_message_text(context.message)
        reply = await self._agent.invoke(
            query or "", task.context_id, on_progress=on_progress
        )

        await updater.add_artifact(parts=[new_text_part(text=reply, media_type="text/plain")])
        await updater.update_status(
            state=TaskState.TASK_STATE_COMPLETED,
            message=new_text_message(reply),
        )

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("cancel is not supported by this example agent")
