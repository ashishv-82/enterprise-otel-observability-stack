"""FastAPI application — fully instrumented with OpenTelemetry (traces, metrics, logs).

All telemetry is sent via OTLP gRPC to the ADOT collector.
Endpoint is read from OTEL_EXPORTER_OTLP_ENDPOINT env var (set in .env).
"""
import logging
import random
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from opentelemetry import metrics as otel_metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

import log_generator
import metrics as app_metrics

_LOGGER = logging.getLogger(__name__)


def setup_telemetry() -> None:
    """Initialise OTel providers for traces, metrics, and logs.

    Reads OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_RESOURCE_ATTRIBUTES from the
    environment automatically — no hardcoded values here.
    """
    # Resource is built from OTEL_RESOURCE_ATTRIBUTES env var (service.name etc.)
    resource = Resource.create()

    # ── Traces ───────────────────────────────────────────────────────────────
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter())
    )
    trace.set_tracer_provider(tracer_provider)

    # ── Metrics ──────────────────────────────────────────────────────────────
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(), export_interval_millis=15_000
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[reader])
    otel_metrics.set_meter_provider(meter_provider)

    # ── Logs ─────────────────────────────────────────────────────────────────
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter())
    )
    set_logger_provider(logger_provider)

    # Bridge Python standard logging → OTel LoggerProvider
    otel_handler = LoggingHandler(level=logging.DEBUG, logger_provider=logger_provider)
    logging.basicConfig(level=logging.DEBUG, handlers=[otel_handler])

    # Configure metric instruments now that the provider is ready
    meter = otel_metrics.get_meter(__name__)
    app_metrics.configure(meter)

    _LOGGER.info("OTel telemetry providers initialised")


# ── App lifecycle ─────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_telemetry()
    log_generator.start()
    yield


app = FastAPI(
    title="OTel Demo App",
    description="FastAPI app instrumented with OpenTelemetry SDK",
    version="0.1.0",
    lifespan=lifespan,
)

FastAPIInstrumentor.instrument_app(app)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health", tags=["ops"])
def health():
    """Liveness probe — always returns 200 if the process is up."""
    return {"status": "ok"}


@app.get("/items", tags=["items"])
def list_items(request: Request):
    """Return a short list of items — generates a trace span per call."""
    if app_metrics.request_count is not None:
        app_metrics.request_count.add(1, {"endpoint": "/items", "method": "GET"})
    return [{"id": i, "name": f"Item {i}", "price": round(random.uniform(1, 100), 2)}
            for i in range(1, 6)]


@app.get("/items/{item_id}", tags=["items"])
def get_item(item_id: int, request: Request):
    """Fetch a single item by ID — generates a trace span with item_id attribute."""
    if app_metrics.request_count is not None:
        app_metrics.request_count.add(1, {"endpoint": "/items/{id}", "method": "GET"})
    if item_id < 1 or item_id > 100:
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
    return {"id": item_id, "name": f"Item {item_id}", "price": round(random.uniform(1, 100), 2)}


@app.get("/crash", tags=["ops"])
def crash():
    """Intentionally raises an unhandled exception — used to test error log and trace correlation."""
    _LOGGER.error("Crash endpoint called — raising intentional exception")
    raise RuntimeError("Intentional crash — triggered by GET /crash")


# ── Global exception handler ──────────────────────────────────────────────────

@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    _LOGGER.exception("Unhandled exception: %s", exc)
    return JSONResponse(
        status_code=500,
        content={"error": type(exc).__name__, "detail": str(exc)},
    )
