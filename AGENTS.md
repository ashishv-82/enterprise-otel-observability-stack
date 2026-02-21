# Agent Instructions — Enterprise OTel Observability Stack

> Read this file at the start of every session before writing any code or making any suggestions.

## Project Overview

A two-phase observability stack for a containerised FastAPI app. The telemetry pipeline is:
**App (OTel SDK) → ADOT Collector → Metrics (Prometheus/AMP) + Logs (Loki) + Traces (X-Ray) → Grafana**

Full architecture and all design decisions are in [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).
Step-by-step build tasks are in [`docs/IMPLEMENTATION_PLAN.md`](./docs/IMPLEMENTATION_PLAN.md) — check off items as you complete them.

---

## General Working Principles

### Session Startup
- Before anything else, re-read this file (`AGENTS.md`) and `docs/ARCHITECTURE.md` to restore full context
- Check the **Current Phase** section below and apply only the rules for that phase
- If the task is ambiguous or touches the architecture, ask — don't assume

### Making Changes
- **One thing at a time.** Make a change, verify it works, then move on. No batching unrelated changes
- **Small and reviewable.** Prefer small, targeted edits over large rewrites
- **Ask before architectural changes.** Any change that affects the ADOT pipeline, service topology, or Terraform structure requires confirmation first
- **No over-engineering.** Solve the specific problem at hand. Do not add abstractions or features not asked for

### Git Hygiene
- Commit messages: `<type>: <short description>` — e.g. `feat: add /crash endpoint`, `fix: correct loki datasource url`, `chore: update adot config`
- Commit after each meaningful, working unit of change — not at the end of a large session
- **Never commit secrets, credentials, or `.env` files.** Use `.gitignore`

### Testing & Verification
- Always verify a change works before declaring it done
- For Docker Compose changes: `docker compose up` and confirm all services are healthy
- For Python changes: run the app and hit the affected endpoints
- For Terraform changes: run `terraform plan` and review the diff before applying

### Code Quality
- No `TODO` or `FIXME` comments left in committed code — either fix it now or create a noted task
- No commented-out code blocks
- No hardcoded values — use environment variables for all endpoints, ports, and credentials
- Keep functions small and single-purpose

### Security
- Credentials and secrets live in `.env` (local, gitignored) or SSM Parameter Store (AWS)
- Never log secrets, tokens, or passwords — not even at DEBUG level
- All `.env*` files must be in `.gitignore`

### Documentation
- If you change a service name, port, or endpoint — update `docker-compose.yml`, `AGENTS.md`, and `docs/ARCHITECTURE.md` accordingly
- If a design decision changes, update the relevant ADR in `docs/ARCHITECTURE.md`

---

## Current Phase

> **🟡 PHASE 1 — Local (Docker Compose)**

Update this line when transitioning to Phase 2.

| Phase | Status | Infra |
|---|---|---|
| Phase 1 — Local | 🟡 In Progress | Docker Compose |
| Phase 2 — AWS | ⬜ Not Started | Terraform + ECS |

---

## Architecture Rules (Non-Negotiable)

These decisions are finalised. Do not suggest alternatives unless explicitly asked.

- **ADOT is the only collector.** The app speaks OTLP to ADOT — never directly to Prometheus, Loki, or X-Ray.
- **Traces go to AWS X-Ray.** Not Grafana Tempo, not Jaeger.
- **Grafana OSS only.** Not Amazon Managed Grafana (AMG). No IAM Identity Center dependency.
- **Secrets in SSM Parameter Store.** Not AWS Secrets Manager.
- **Terraform state in S3 + DynamoDB.** Not Terraform Cloud.
- **Phase 1 → Phase 2 is config changes, not code changes.** App instrumentation and Grafana dashboards must not be environment-specific.

---

## Phase 1 — Local Do's and Don'ts

### ✅ Do
- Use `docker-compose.yml` for all services
- Use **MinIO** to simulate S3 for Loki storage
- Use `amazon/aws-xray-daemon` container as the local trace endpoint
- Use environment variables to configure ADOT and app endpoints (not hardcoded)
- Provision Grafana datasources and dashboards via config files (not the UI)

### ❌ Don't
- Do not create or modify any AWS resources during Phase 1
- Do not write environment-specific code paths in the Python app
- Do not use `boto3` or any AWS SDK calls in the app during Phase 1
- Do not hardcode `localhost` — use Docker Compose service names (e.g., `prometheus:9090`)

---

## Phase 2 — AWS Do's and Don'ts

### ✅ Do
- All AWS resources defined in Terraform under `terraform/`
- Use ECS Fargate for all services (App+ADOT sidecar, Loki, Grafana)
- Store sensitive values (endpoints, passwords) in SSM Parameter Store; inject into ECS Task Definitions as env vars
- Reuse the same Docker images built in Phase 1 — push to ECR

### ❌ Don't
- Do not use `terraform apply` locally without remote state configured first
- Do not hardcode AWS account IDs or region strings — use variables

---

## Project Conventions

### Python App
- **A Python virtual environment (`.venv`) is mandatory.** Always activate it before any local Python work:
  ```bash
  source .venv/bin/activate
  ```
- Create it if it doesn't exist: `python3 -m venv .venv && pip install -r requirements-dev.txt`
- `requirements-dev.txt` (project root) — local dev tooling (pytest, pyyaml, httpx, locust)
- `app/requirements.txt` — FastAPI app dependencies (used inside Docker only)
- Use `opentelemetry-sdk` and `opentelemetry-exporter-otlp` — no other telemetry libraries
- **WARNING:** The Python OTel SDK requires `OTEL_EXPORTER_OTLP_ENDPOINT` to be explicitly set. Without a default value, it silently drops telemetry.
- Emit all telemetry via OTLP to the ADOT collector endpoint (`OTEL_EXPORTER_OTLP_ENDPOINT`)
- Custom metrics use the OTel `Gauge` API (not Prometheus client library directly)
- Background log generator runs as a `threading.Thread` started at app startup

### ADOT Config
- Config lives at `adot/config.yaml`
- Swap between local and AWS by changing exporter endpoints only — pipeline structure stays the same
- **WARNING:** The `awsxray` exporter in ADOT requires valid AWS credentials to initialise, even when `local_mode: true` is set. Pass `AWS_ACCESS_KEY_ID=dummy` via environment variables and use `AWS_XRAY_DAEMON_ADDRESS` to route traces locally without an `endpoint` setting.

### Grafana
- Datasource provisioning: `grafana/provisioning/datasources/`
- Dashboard provisioning: `grafana/provisioning/dashboards/`
- Dashboards stored as JSON in `grafana/dashboards/`
- Never save dashboards via the Grafana UI — always edit JSON files

### Terraform
- All Terraform code lives under `terraform/`
- Remote state backend configured in `terraform/backend.tf`
- Separate files per resource group: `ecs.tf`, `amp.tf`, `s3.tf`, `iam.tf`, etc.

### File Structure (Target)
```
.
├── app/                  # FastAPI app + OTel instrumentation
├── adot/                 # ADOT collector config
├── grafana/              # Datasources, dashboards, provisioning
├── locust/               # Load test scripts
├── terraform/            # All IaC (Phase 2)
├── .github/workflows/    # CI/CD (Phase 2)
├── docker-compose.yml    # Phase 1 local stack
├── docs/                 
│   ├── ARCHITECTURE.md   # Full architecture + ADRs
│   └── IMPLEMENTATION_PLAN.md # Build checklist
├── AGENTS.md             # This file
└── README.md             # Project overview
```

---

## Key Validation Milestone

**Phase 1 is complete when:** A Locust load test creates a visible spike on a Grafana dashboard panel on `localhost`, AND a request to `/crash` shows a correlated error log and trace in Grafana.
