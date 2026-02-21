"""Custom OTel metric instruments for the FastAPI app.

Must be configured by calling configure(meter) once, after the MeterProvider is set up.
All instruments live here and are imported by main.py route handlers.
"""
from __future__ import annotations

import random
from typing import Iterable

from opentelemetry.metrics import CallbackOptions, Counter, Observation

# Populated by configure() at startup — will be None before that
request_count: Counter | None = None

# Internal gauge state — updated by the log generator background thread
_active_users: float = 0.0


def configure(meter) -> None:
    """Initialise all metric instruments. Call exactly once after MeterProvider is set."""
    global request_count

    request_count = meter.create_counter(
        name="http_request_count",
        description="Total number of HTTP requests received by the app",
        unit="1",
    )

    # ObservableGauge: value is read by the SDK at each collection cycle
    meter.create_observable_gauge(
        name="active_simulated_users",
        callbacks=[_observe_active_users],
        description="Number of simulated active users (updated by background thread)",
        unit="1",
    )


def set_active_users(value: float) -> None:
    """Set the current simulated-user count (called from the background thread)."""
    global _active_users
    _active_users = value


def _observe_active_users(options: CallbackOptions) -> Iterable[Observation]:
    yield Observation(_active_users)
