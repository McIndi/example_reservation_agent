"""OpenTelemetry setup for the reservation agent.

Rossoctl sets OTEL_EXPORTER_OTLP_ENDPOINT on every agent it deploys,
pointed at the collector's OTLP/HTTP receiver on :8335 (the gRPC
receiver is a different port, :4317, and this agent does not use it).
The variable was already there before this module existed - nothing
in the process ever read it, so no spans ever left the pod. Follows
docs/agents/otel-instrumentation.md in the rossoctl repo, which is the
platform's own reference for span names and gen_ai.* / openinference.*
attributes.

Absent the endpoint, init_tracing() is a no-op: start_as_current_span
still works against the SDK's default no-op provider, so callers never
need to check whether tracing is configured.
"""
from __future__ import annotations

import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# Matches the Deployment name, which is what the other Rossoctl demo
# agents use as their Phoenix/trace service name too.
AGENT_NAME = "reservation-agent"

_initialized = False


def init_tracing() -> None:
    global _initialized
    if _initialized:
        return
    _initialized = True

    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        return

    provider = TracerProvider(resource=Resource.create({"service.name": AGENT_NAME}))
    exporter = OTLPSpanExporter(endpoint=f"{endpoint.rstrip('/')}/v1/traces")
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)


def get_tracer():
    return trace.get_tracer(AGENT_NAME)
