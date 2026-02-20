# Implementation Plan

> Reference this document during every build session alongside `AGENTS.md`.
> Check off items as they are completed. Do not skip steps — each builds on the previous.

---

## Phase 1 — Local Stack (Docker Compose)

**Goal:** A fully wired local observability stack where Locust traffic produces visible spikes in Grafana, and `/crash` shows Log-to-Trace correlation.

---

### Step 1 — Project Scaffolding

- [x] Create directory structure:
  ```
  app/ adot/ grafana/provisioning/datasources/ grafana/provisioning/dashboards/
  grafana/dashboards/ locust/ terraform/
  ```
- [x] Create `.gitignore` — include `.env`, `*.tfstate`, `.terraform/`, `__pycache__/`
- [x] Create `.env.example` with all required env var keys (no values)
- [x] Create `docker-compose.yml` skeleton with service stubs
- [x] Create `prometheus.yml` and `loki-config.yaml` supporting configs
- [x] Copy `.env.example` → `.env`

**Done when:** `docker compose config` validates without errors. ⚠️ Deferred — start Docker Desktop and run `docker compose config` to confirm at next session start.

---

### Step 2 — FastAPI Application (`app/`)

- [ ] `app/main.py` — FastAPI app with:
  - [ ] OTel SDK setup: `TracerProvider`, `MeterProvider`, `LoggerProvider`
  - [ ] OTLP exporter configured from `OTEL_EXPORTER_OTLP_ENDPOINT` env var
  - [ ] Auto-instrumentation for FastAPI via `FastAPIInstrumentor`
  - [ ] Health check endpoint: `GET /health` → `{"status": "ok"}`
  - [ ] Crash endpoint: `GET /crash` → raises unhandled exception → 500 + stack trace
  - [ ] A few sample endpoints to generate varied traces: `GET /items`, `GET /items/{id}`
- [ ] `app/metrics.py` — Custom OTel metrics:
  - [ ] `active_simulated_users` Gauge (updated by background thread)
  - [ ] `request_count` Counter (incremented per request)
- [ ] `app/log_generator.py` — Background thread:
  - [ ] Runs every 5–10 seconds
  - [ ] Emits random mix of `INFO`, `WARNING`, `ERROR` log records via OTel Logger
  - [ ] **Crucial:** Ensure the OTel `Resource` (with `service.name`) is attached to logs so Loki can filter them
- [ ] `app/requirements.txt` — Pin all dependencies
- [ ] `app/Dockerfile` — Multi-stage build, non-root user

**Done when:** `docker compose up app` starts, `GET /health` returns 200, `GET /crash` returns 500 with trace in response.

---

### Step 3 — ADOT Collector Config (`adot/`)

- [ ] `adot/config.yaml` with:
  - [ ] **Receiver:** `otlp` (grpc: 4317, http: 4318)
  - [ ] **Processors:** `batch`, `resourcedetection`
  - [ ] **Exporters:**
    - [ ] `prometheusremotewrite` → `http://prometheus:9090/api/v1/write`
    - [ ] `loki` → `http://loki:3100/loki/api/v1/push`
    - [ ] `awsxray` → `http://xray-daemon:2000`
  - [ ] **Pipelines:** `traces`, `metrics`, `logs` all wired through the above

**Done when:** ADOT container starts without config errors and logs show receivers/exporters active.

---

### Step 4 — Docker Compose (`docker-compose.yml`)

Wire all 7 services with correct dependencies and env vars:

- [ ] `app` — FastAPI; depends on `adot`
- [ ] `adot` — ADOT collector; image: `public.ecr.aws/aws-observability/aws-otel-collector:latest`
- [ ] `prometheus` — `prom/prometheus`; expose port 9090; mount `prometheus.yml`
- [ ] `loki` — `grafana/loki`; expose port 3100; mount `loki-config.yaml`; volume for MinIO storage
- [ ] `minio` — `minio/minio`; S3-compatible storage for Loki; expose ports 9000/9001
- [ ] `xray-daemon` — `amazon/aws-xray-daemon`; expose port 2000/UDP
- [ ] `grafana` — `grafana/grafana-oss`; expose port 3000; mount provisioning dirs
- [ ] `locust` — custom image from `locust/`; profile `--profile load` so it doesn't start by default

Supporting configs to create:
- [ ] `prometheus.yml` — scrape configs for app metrics
- [ ] `loki-config.yaml` — filesystem/MinIO storage config
- [ ] `.env` — local env vars (gitignored)

**Done when:** `docker compose up` starts all 6 core services healthy. Grafana accessible at `localhost:3000`.

---

### Step 5 — Grafana Provisioning (`grafana/`)

- [ ] `grafana/provisioning/datasources/datasources.yaml`:
  - [ ] Prometheus datasource → `http://prometheus:9090`
  - [ ] Loki datasource → `http://loki:3100`
  - [ ] X-Ray datasource → AWS X-Ray (using local dummy credentials for daemon mode)
- [ ] `grafana/provisioning/dashboards/dashboards.yaml` — point to `grafana/dashboards/`
- [ ] `grafana/dashboards/overview.json` — Main dashboard with panels:
  - [ ] Request rate (Prometheus)
  - [ ] Error rate / 5xx count (Prometheus)
  - [ ] `active_simulated_users` Gauge (Prometheus)
  - [ ] Log stream panel (Loki) — filterable by level
  - [ ] Latency percentiles p50/p95/p99 (Prometheus)

**Done when:** Grafana starts, all datasources show green, and the overview dashboard renders with data.

---

### Step 6 — Locust Load Test (`locust/`)

- [ ] `locust/locustfile.py`:
  - [ ] `HttpUser` with tasks hitting `GET /items`, `GET /items/{id}` at varying weights
  - [ ] A low-frequency task hitting `GET /crash` (to generate error traces)
  - [ ] Wait time: `between(0.5, 3)` seconds
- [ ] `locust/Dockerfile`
- [ ] Add `locust` service to `docker-compose.yml` under `--profile load`

**Done when:** Running `docker compose --profile load up locust` sends traffic and Prometheus shows a request rate spike.

---

### Step 7 — Phase 1 Validation ✅

- [ ] `docker compose up` — all 6 core services start and stay healthy
- [ ] `GET /health` → 200
- [ ] `GET /crash` → 500 with stack trace in Loki logs
- [ ] Locust started → request rate panel in Grafana shows a spike
- [ ] Loki log panel shows ERROR entries from `/crash`
- [ ] X-Ray trace visible for a `/crash` request
- [ ] Log entry in Loki links to its X-Ray trace (Log-to-Trace correlation)

**Phase 1 is complete when all validation steps above pass.**

---

## Phase 2 — AWS Deployment (Terraform + ECS)

> Start Phase 2 only after Phase 1 validation is complete.
> Update `AGENTS.md` Current Phase to Phase 2 before starting.

---

### Step 8 — Local AWS Auth & Terraform State Bootstrap

- [ ] Ensure local AWS authentication is active (e.g., `aws sso login` or valid `~/.aws/credentials`)
- [ ] Create S3 bucket for TF state (manually or via a bootstrap script) — versioning enabled
- [ ] Create DynamoDB table for state locking (`LockID` string key)
- [ ] `terraform/backend.tf` — configure S3 backend with bucket/key/region/dynamodb_table

**Done when:** `terraform init` succeeds with remote backend.

---

### Step 9 — Core AWS Infrastructure (`terraform/`)

- [ ] `terraform/variables.tf` — `aws_region`, `project_name`, `environment`
- [ ] `terraform/vpc.tf` — VPC, public/private subnets, NAT Gateway, Internet Gateway
- [ ] `terraform/ecs.tf` — ECS Cluster (Fargate)
- [ ] `terraform/ecr.tf` — ECR repository for the FastAPI app image
- [ ] `terraform/iam.tf` — ECS task execution role and task role with least-privilege policies
- [ ] `terraform/security_groups.tf` — SGs for each ECS service

**Done when:** `terraform plan` shows expected resources with no errors.

---

### Step 10 — Observability Infrastructure

- [ ] `terraform/amp.tf` — Amazon Managed Prometheus workspace; output remote write URL
- [ ] `terraform/s3.tf` — S3 bucket for Loki chunk storage; versioning + lifecycle rules
- [ ] `terraform/ssm.tf` — SSM parameters for AMP URL, Loki S3 bucket name, Grafana credentials

**Done when:** `terraform apply` provisions AMP workspace and S3 bucket; SSM parameters created.

---

### Step 11 — ECS Services

- [ ] **App + ADOT sidecar** (`terraform/ecs_app.tf`):
  - [ ] Task definition with two containers: `app` and `adot`
  - [ ] ADOT config injected via SSM; endpoints updated to point to AMP, Loki-on-ECS, X-Ray
  - [ ] ECS Service with desired count 1; ALB target group
- [ ] **Loki** (`terraform/ecs_loki.tf`):
  - [ ] Task definition with S3 backend config
  - [ ] ECS Service; internal ALB or service discovery
- [ ] **Grafana** (`terraform/ecs_grafana.tf`):
  - [ ] Task definition with provisioning configs mounted from SSM / S3
  - [ ] ECS Service; public-facing ALB; security group allows 443/80
- [ ] `terraform/alb.tf` — Application Load Balancers for App and Grafana

**Done when:** `terraform apply` deploys all three ECS services; Grafana accessible via ALB DNS.

---

### Step 12 — CI/CD Pipeline (`.github/workflows/`)

- [ ] `.github/workflows/deploy.yml`:
  - [ ] Trigger: push to `main`
  - [ ] Steps:
    1. Checkout
    2. Configure AWS credentials (OIDC — no long-lived keys)
    3. Build and push app image to ECR
    4. `terraform init`
    5. `terraform plan`
    6. `terraform apply -auto-approve`
- [ ] GitHub secrets: `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`
- [ ] OIDC role in AWS IAM (`terraform/iam_github.tf`) with trust policy for GitHub Actions

**Done when:** A push to `main` triggers the workflow; ECS service updates to new image.

---

### Step 13 — Phase 2 Validation ✅

- [ ] Grafana ALB URL accessible in browser
- [ ] All Grafana datasources (AMP, Loki, X-Ray) show green
- [ ] Overview dashboard renders with live data from AWS
- [ ] Locust run (ad-hoc) creates a spike on the AMP-backed dashboard
- [ ] `/crash` endpoint produces a log in Loki + trace in X-Ray + they are correlated in Grafana
- [ ] `terraform destroy` tears everything down cleanly (S3/DynamoDB state persists)

**Phase 2 is complete when all validation steps above pass.**
