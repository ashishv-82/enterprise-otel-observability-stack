# ── Stage 1: dependency builder ──────────────────────────────────────────────
FROM python:3.12-slim AS builder

RUN python -m venv /venv

COPY requirements.txt .
RUN /venv/bin/pip install --no-cache-dir -r requirements.txt


# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

WORKDIR /app

# Copy the complete virtual environment from builder
COPY --from=builder /venv /venv

# Create a non-root system user and group
RUN groupadd --system appgroup && \
    useradd --system --gid appgroup --no-create-home --shell /sbin/nologin appuser

# Copy app source with correct ownership
COPY --chown=appuser:appgroup . .

USER appuser

# Put the venv on PATH so all python/uvicorn commands use it
ENV PATH="/venv/bin:$PATH"

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--log-level", "info"]
