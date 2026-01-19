#!/usr/bin/env python3
"""
N8N Event Log → OpenTelemetry Trace Exporter
Emits one span per workflow execution
"""

import json
import time
import re
import os
import signal
import sys
from datetime import datetime

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.trace import Status, StatusCode

# --- Configuration ---
LOG_FILE = "/n8n-data/n8nEventLog.log"
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
                          "http://otel-collector.monitoring.svc.cluster.local:4318/v1/traces")
SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "n8n")

# --- Tracing setup ---
executions = {}


def to_ns(ts: str) -> int:
    """Convert ISO timestamp string to nanoseconds"""
    return int(
        datetime.fromisoformat(ts.replace("Z", "+00:00")
                               ).timestamp() * 1_000_000_000
    )


resource = Resource.create({
    "service.name": SERVICE_NAME,
    "k8s.pod.name": os.getenv("POD_NAME"),
    "k8s.namespace.name": os.getenv("POD_NAMESPACE"),
})

provider = TracerProvider(resource=resource)
processor = BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT))
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("n8n.flow")

log_re = re.compile(
    r'([\d-]+T[\d:.]+Z)\s+\|\s+(\w+)\s+\|\s+(.+?)(?:\s+(\{.+\}))?$'
)

# --- Helpers ---


def parse(line):
    """Parse a log line into timestamp, level, message, json data"""
    m = log_re.match(line)
    if not m:
        return None
    ts, level, msg, js = m.groups()
    data = {}
    if js:
        try:
            data = json.loads(js)
        except Exception:
            pass
    return ts, level, msg, data


def shutdown(*_):
    """Flush open spans before shutting down"""
    print("Flushing spans before shutdown")
    for span in executions.values():
        try:
            span.end()
        except Exception:
            pass
    provider.shutdown()
    sys.exit(0)


signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

# --- Main tailing loop ---


def tail():
    """Tail the log file, creating it if necessary, and process events"""
    # Wait until the file exists
    while not os.path.exists(LOG_FILE):
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        open(LOG_FILE, "a").close()  # create empty file
        print(f"Waiting for log file {LOG_FILE}...")
        time.sleep(1)

    print(f"Watching log file {LOG_FILE}")
    with open(LOG_FILE, "r") as f:
        f.seek(0, 2)  # go to end

        while True:
            line = f.readline()
            if not line:
                time.sleep(0.1)
                continue

            parsed = parse(line.strip())
            if not parsed:
                continue

            ts, level, msg, data = parsed
            execution_id = data.get("executionId")

            # Workflow execution started
            if "Workflow execution started" in msg:
                workflow_id = data.get("workflowId", "unknown")
                if execution_id:
                    span = tracer.start_span(
                        name=f"workflow.{workflow_id}",
                        start_time=to_ns(ts),
                        attributes={
                            "workflow.id": workflow_id,
                            "execution.id": execution_id,
                        }
                    )
                    executions[execution_id] = span

            # Workflow execution finished
            elif "Workflow execution finished" in msg:
                if execution_id and execution_id in executions:
                    span = executions.pop(execution_id)
                    span.set_status(Status(StatusCode.OK))
                    span.end(end_time=to_ns(ts))

            # Handle errors
            elif level.lower() == "error" and execution_id:
                span = executions.get(execution_id)
                if span:
                    span.set_status(Status(StatusCode.ERROR))
                    span.add_event("error", {"message": msg})


if __name__ == "__main__":
    tail()
