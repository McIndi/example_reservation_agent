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
from opentelemetry.trace import SpanKind, Status, StatusCode

from . import tracing
from .agent import ReservationAgent


def _authorization(context: RequestContext) -> str | None:
    """Pull the caller's Authorization header off the inbound request.

    a2a-sdk stashes the inbound headers on the call context, which is the
    only place the customer's identity is available to this agent. It has to
    ride along on every outbound tool call, because AuthBridge forwards what
    this process sends rather than minting anything itself.
    """
    call_context = getattr(context, "call_context", None)
    state = getattr(call_context, "state", None) or {}
    headers = state.get("headers") or {}
    return headers.get("authorization") or headers.get("Authorization")


class ReservationAgentExecutor(AgentExecutor):
    def __init__(self) -> None:
        self._agent = ReservationAgent()
        self._tracer = tracing.get_tracer()

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

        # Root span for the whole turn. Named and attributed per
        # docs/agents/otel-instrumentation.md in the rossoctl repo: the
        # gen_ai.* attributes are what Phoenix's and MLflow's OTEL Collector
        # transforms key off of.
        with self._tracer.start_as_current_span(
            f"invoke_agent {tracing.AGENT_NAME}", kind=SpanKind.INTERNAL
        ) as span:
            span.set_attribute("gen_ai.operation.name", "invoke_agent")
            span.set_attribute("gen_ai.provider.name", "openai")
            span.set_attribute("gen_ai.agent.name", tracing.AGENT_NAME)
            span.set_attribute("gen_ai.conversation.id", task.context_id)
            span.set_attribute("openinference.span.kind", "AGENT")
            span.set_attribute("input.value", query or "")
            try:
                reply = await self._agent.invoke(
                    query or "",
                    task.context_id,
                    on_progress=on_progress,
                    authorization=_authorization(context),
                )
                span.set_attribute("output.value", reply)
                span.set_status(Status(StatusCode.OK))
            except Exception as exc:
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                span.record_exception(exc)
                raise

        # The reply goes out once. Sending it as an artifact and again as the
        # terminal status message made Rossoctl's chat render both, so the
        # customer saw the whole answer twice, run together in one bubble.
        await updater.add_artifact(parts=[new_text_part(text=reply, media_type="text/plain")])
        await updater.update_status(state=TaskState.TASK_STATE_COMPLETED)

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("cancel is not supported by this example agent")
