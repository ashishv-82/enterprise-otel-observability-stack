"""Background log generator.

Runs as a daemon thread, emitting random log records at varying levels so the
Loki log stream always has live data — no manual traffic required.
Also updates the active_simulated_users gauge.
"""
import logging
import random
import threading
import time

import metrics as app_metrics

logger = logging.getLogger("log_generator")

_INFO_MSGS = [
    "User session initialised",
    "Cache hit — returning stored result",
    "Health check passed",
    "Database query completed in 12ms",
    "Config reloaded successfully",
    "Background task completed",
    "Outgoing request dispatched",
    "Response serialised in 3ms",
]

_WARNING_MSGS = [
    "Cache miss — fetching from origin",
    "Slow database query detected (>200ms)",
    "Retry attempt 1/3 for downstream service",
    "Memory usage above 70%",
    "Rate limit approaching for external API",
    "Deprecated endpoint called — please migrate",
]

_ERROR_MSGS = [
    "Database connection timed out",
    "Failed to reach downstream service",
    "Unexpected null value in response payload",
    "Serialisation error — skipping record",
    "Auth token validation failed",
]

_LEVELS = [logging.INFO, logging.WARNING, logging.ERROR]
_WEIGHTS = [6, 3, 1]  # mostly INFO, occasional WARNING, rare ERROR


def _run() -> None:
    while True:
        time.sleep(random.uniform(5, 10))

        level = random.choices(_LEVELS, weights=_WEIGHTS, k=1)[0]
        if level == logging.INFO:
            logger.info(random.choice(_INFO_MSGS))
        elif level == logging.WARNING:
            logger.warning(random.choice(_WARNING_MSGS))
        else:
            logger.error(random.choice(_ERROR_MSGS))

        # Drive the active_simulated_users gauge
        app_metrics.set_active_users(random.uniform(0, 50))


def start() -> None:
    """Start the background log generator daemon thread."""
    thread = threading.Thread(target=_run, daemon=True, name="log-generator")
    thread.start()
    logger.info("Log generator thread started")
