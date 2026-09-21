"""
obs-lab demoapp - a deliberately imperfect service for the observability lab.

Endpoints:
  GET  /api/items      fast, healthy baseline
  GET  /api/search     bimodal latency (p99 >> p50) - the "cold index" tail
  POST /api/checkout   ~8% error rate, worse with CHAOS_LEVEL
  GET  /api/report     emits a high-cardinality label when CARDINALITY=1 (the trap)
  GET  /healthz        liveness
  GET  /readyz         readiness
  GET  /metrics        Prometheus exposition

Logging (added in 1.1.0, for scenario 02):
  One JSON object per line on stdout, one line per request. Every line carries
  a trace_id, which Alloy attaches as structured metadata rather than as a
  stream label - see scenario-02-logs/helm/alloy.values.yaml.

Env:
  CHAOS_LEVEL   0..3   default 0. Raises error rate + latency on /api/checkout.
  CARDINALITY   0|1    default 0. Enables the cardinality bomb on /api/report.
  WORKER_NAME   str    label value for queue metrics. Default: pod hostname.
  LOG_LEVEL     str    default info. debug adds a line per request start.
"""

import asyncio
import json
import os
import random
import socket
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

CHAOS_LEVEL = int(os.getenv("CHAOS_LEVEL", "0"))
CARDINALITY = os.getenv("CARDINALITY", "0") == "1"
WORKER_NAME = os.getenv("WORKER_NAME", socket.gethostname())
LOG_LEVEL = os.getenv("LOG_LEVEL", "info").lower()

# A dedicated registry keeps the exposition clean: only our metrics plus the
# python_* defaults we explicitly opt into. Using the global REGISTRY would
# pull in process collectors automatically - fine in production, noisy in a lab.
registry = CollectorRegistry()

# --- Metric definitions -------------------------------------------------
# The label sets below are the whole lesson. Every distinct combination of
# label values is one time series in Prometheus. Keep them bounded.

http_requests_total = Counter(
    "demoapp_http_requests_total",
    "Total HTTP requests.",
    ["method", "route", "status"],
    registry=registry,
)

http_request_duration_seconds = Histogram(
    "demoapp_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["route"],
    # Buckets chosen for a web API. The library defaults are almost never
    # right for your service - pick buckets around your actual SLO.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
    registry=registry,
)

queue_depth = Gauge(
    "demoapp_queue_depth",
    "Simulated background queue depth.",
    ["worker"],
    registry=registry,
)

build_info = Gauge(
    "demoapp_build_info",
    "Build metadata. Always 1; the labels carry the information.",
    ["version", "chaos_level"],
    registry=registry,
)

# THE TRAP. Exercise 5 makes you find and kill this one.
report_requests_total = Counter(
    "demoapp_report_requests_total",
    "Report requests, labelled by request id (INTENTIONALLY BAD).",
    ["request_id"],
    registry=registry,
)

APP_VERSION = "1.1.0"
build_info.labels(version=APP_VERSION, chaos_level=str(CHAOS_LEVEL)).set(1)

# Initialise the gauge immediately. A gauge that only appears once the
# background loop has ticked makes its Grafana panel blank on a fresh deploy,
# and "no data" is the one thing a dashboard should never say by default.
queue_depth.labels(worker=WORKER_NAME).set(0)


async def _background_queue() -> None:
    """Sawtooth queue depth so the gauge panel has something to say."""
    depth = 0.0
    while True:
        depth += random.uniform(-3, 5) + CHAOS_LEVEL * 2
        depth = max(0.0, min(depth, 500.0))
        queue_depth.labels(worker=WORKER_NAME).set(depth)
        await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(_: FastAPI):
    _log(
        "info",
        "demoapp starting",
        chaos_level=CHAOS_LEVEL,
        cardinality=CARDINALITY,
    )
    task = asyncio.create_task(_background_queue())
    yield
    _log("info", "demoapp shutting down")
    task.cancel()


app = FastAPI(title="obs-lab demoapp", version=APP_VERSION, lifespan=lifespan)


# --- Logging ------------------------------------------------------------
# One JSON object per line, written straight to stdout. No logging module and
# no formatter: the container runtime captures stdout, Alloy tails the file
# the runtime writes, and anything clever in between is one more thing that
# can reorder or swallow a line.
#
# The field names here are a contract. Scenario 02's LogQL queries parse them
# by name, so renaming `duration_ms` breaks every exercise that unwraps it.


def _log(level: str, msg: str, **fields) -> None:
    if LOG_LEVEL != "debug" and level == "debug":
        return
    record = {
        "ts": datetime.now(timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]
        + "Z",
        "level": level,
        "msg": msg,
        "service": "demoapp",
        "version": APP_VERSION,
        "pod": WORKER_NAME,
        **fields,
    }
    # separators: compact output. The default json.dumps puts a space after
    # every colon and comma, which is ~8% more bytes for no information -
    # and in Loki you pay for bytes ingested.
    sys.stdout.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _observe(
    method: str, route: str, status: int, started: float, **log_fields
) -> None:
    """Record the metrics AND write the log line for one request.

    Both signals come from the same call site on purpose. When the log says
    500 and the metric says 201, you want to be able to rule out "two
    different code paths disagreed" immediately.
    """
    elapsed = time.perf_counter() - started
    http_requests_total.labels(method=method, route=route, status=str(status)).inc()
    http_request_duration_seconds.labels(route=route).observe(elapsed)

    _log(
        "error" if status >= 500 else "info",
        "request completed",
        method=method,
        route=route,
        status=status,
        duration_ms=round(elapsed * 1000, 2),
        # trace_id is unique per request. As a Loki stream LABEL this would be
        # catastrophic - one stream per request. Alloy lifts it into
        # structured metadata instead, which is queryable without being
        # indexed. Scenario 02, exercise 7.
        trace_id=uuid.uuid4().hex[:16],
        **log_fields,
    )


@app.get("/api/items")
async def items():
    started = time.perf_counter()
    await asyncio.sleep(abs(random.gauss(0.03, 0.01)))
    _observe("GET", "/api/items", 200, started)
    return {"items": [{"id": i, "name": f"item-{i}"} for i in range(5)]}


@app.get("/api/search")
async def search(q: str = "laptop"):
    """Bimodal latency: most requests fast, a long tail from a 'cold index'."""
    started = time.perf_counter()
    cold = random.random() < 0.12
    if cold:
        await asyncio.sleep(random.uniform(0.8, 2.5))  # cold path
    else:
        await asyncio.sleep(abs(random.gauss(0.06, 0.02)))
    # index_state is the field that EXPLAINS the bimodal histogram. The metric
    # can show you two humps; only the log can tell you which requests were in
    # which hump and why.
    _observe("GET", "/api/search", 200, started, index_state="cold" if cold else "warm")
    return {"query": q, "hits": random.randint(0, 40)}


@app.post("/api/checkout", status_code=201)
async def checkout():
    started = time.perf_counter()
    error_rate = 0.08 + CHAOS_LEVEL * 0.12
    await asyncio.sleep(abs(random.gauss(0.12 + CHAOS_LEVEL * 0.2, 0.04)))
    if random.random() < error_rate:
        _observe(
            "POST",
            "/api/checkout",
            500,
            started,
            error="payment gateway timeout",
            upstream="billing",
        )
        raise HTTPException(status_code=500, detail="payment gateway timeout")
    _observe("POST", "/api/checkout", 201, started)
    return {"order_id": str(uuid.uuid4()), "status": "confirmed"}


@app.get("/api/report")
async def report():
    started = time.perf_counter()
    rid = str(uuid.uuid4())
    if CARDINALITY:
        # Every request creates a NEW time series. This is the bug.
        report_requests_total.labels(request_id=rid).inc()
    else:
        report_requests_total.labels(request_id="aggregated").inc()
    await asyncio.sleep(abs(random.gauss(0.05, 0.01)))
    _observe("GET", "/api/report", 200, started)
    return {"report_id": rid}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    return {"status": "ready"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)
