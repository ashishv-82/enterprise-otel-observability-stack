# Implementation Plan

> Reference this document during every build session alongside `AGENTS.md`.
> Check off items as they are completed. Do not skip steps — each builds on the previous.

---

## Phase 1 — Local Stack (Docker Compose)

**Goal:** A fully wired local observability stack where Locust traffic produces visible spikes in Grafana, and `/crash` shows Log-to-Trace correlation.

---

### Step 1 — Project Scaffolding
**Brief:** Set up the foundational folder structure, environment variables, ignore files, and local development tooling.

- [x] Create directory structure:
  ```
  app/ adot/ grafana/provisioning/datasources/ grafana/provisioning/dashboards/
  grafana/dashboard-definitions/ locust/ terraform/
  ```
- [x] Create `.gitignore` — include `.env`, `*.tfstate`, `.terraform/`, `__pycache__/`
- [x] Create `.env.example` with all required env var keys (no values)
- [x] Create `docker-compose.yml` skeleton with service stubs
- [x] Create `prometheus.yml` and `loki-config.yaml` supporting configs
- [x] Copy `.env.example` → `.env`

**Done when:** `docker compose config` validates without errors. ✅ Verified.

---

### Step 2 — FastAPI Application (`app/`)
**Brief:** Build the target application instrumented with the OpenTelemetry SDK to generate traces, metrics, and logs natively.

- [x] `app/main.py` — FastAPI app with:
  - [x] OTel SDK setup: `TracerProvider`, `MeterProvider`, `LoggerProvider`
  - [x] OTLP exporter configured from `OTEL_EXPORTER_OTLP_ENDPOINT` env var
  - [x] Auto-instrumentation for FastAPI via `FastAPIInstrumentor`
  - [x] Health check endpoint: `GET /health` → `{"status": "ok"}`
  - [x] Crash endpoint: `GET /crash` → raises unhandled exception → 500 + error detail
  - [x] Sample endpoints: `GET /items`, `GET /items/{id}`
- [x] `app/metrics.py` — Custom OTel metrics:
  - [x] `active_simulated_users` Observable Gauge (updated by background thread)
  - [x] `request_count` Counter (incremented per request)
- [x] `app/log_generator.py` — Background thread:
  - [x] Runs every 5–10 seconds
  - [x] Emits random mix of `INFO`, `WARNING`, `ERROR` log records via OTel Logger
  - [x] OTel `Resource` (with `service.name`) attached via `LoggerProvider`
- [x] `app/requirements.txt` — Pinned dependencies (note: `setuptools==69.5.1` required for `pkg_resources` compat with OTel instrumentation)
- [x] `app/Dockerfile` — Venv-based multi-stage build, non-root user

**Done when:** `docker compose up app` starts, `GET /health` returns 200, `GET /crash` returns 500 with error detail. ✅ Verified.

---

### Step 3 — ADOT Collector Config (`adot/`)
**Brief:** Configure the AWS Distro for OpenTelemetry (ADOT) collector to receive all telemetry from the app and route it to local backend storage containers.

- [x] `adot/config.yaml` with:
  - [x] **Receiver:** `otlp` (grpc: 4317, http: 4318)
  - [x] **Processors:** `batch`, `resourcedetection`
  - [x] **Exporters:**
    - [x] `prometheusremotewrite` → `http://prometheus:9090/api/v1/write`
    - [x] `otlphttp/loki` → `http://loki:3100/otlp` (standard OTLP natively accepted by Loki)
    - [x] `awsxray` → `http://xray-daemon:2000`
  - [x] **Pipelines:** `traces`, `metrics`, `logs` all wired through the above

**Done when:** ADOT container starts without config errors and logs show receivers/exporters active. ✅ Verified.

---

### Step 4 — Docker Compose (`docker-compose.yml`)
**Brief:** Wire together the entire local observability platform (App, ADOT, Prometheus, Loki, MinIO, X-Ray, Grafana) into a cohesive runnable stack.

Wire all 7 services with correct dependencies and env vars:

- [x] `app` — FastAPI; depends on `adot` (requires `OTEL_EXPORTER_OTLP_ENDPOINT` pointing to ADOT)
- [x] `adot` — ADOT collector; requires dummy `AWS_ACCESS_KEY_ID` to bypass SDK auth checks locally
- [x] `prometheus` — `prom/prometheus`; expose port 9090; mount `prometheus.yml`
- [x] `loki` — `grafana/loki`; expose port 3100; mount `loki-config.yaml`; volume for MinIO storage
- [x] `minio` — `minio/minio`; S3-compatible storage for Loki; expose ports 9000/9001
- [x] `xray-daemon` — `amazon/aws-xray-daemon`; expose port 2000/UDP
- [x] `grafana` — `grafana/grafana-oss`; expose port 3000; mount provisioning dirs and `grafana/dashboard-definitions`
- [x] `locust` — custom image from `locust/`; profile `--profile load` so it doesn't start by default

Supporting configs to create:
- [x] `prometheus.yml` — scrape configs for app metrics
- [x] `loki-config.yaml` — filesystem/MinIO storage config
- [x] `.env` — local env vars (gitignored)

**Done when:** `docker compose config` is valid and the stack is ready to boot. ✅ Verified.

---

### Step 5 — Grafana Provisioning (`grafana/`)
**Brief:** Define Grafana datasources and dashboards as code so Grafana boots up fully configured without requiring manual UI setup.

- [x] `grafana/provisioning/datasources/datasources.yaml`:
  - [x] Prometheus datasource → `http://prometheus:9090`
  - [x] Loki datasource → `http://loki:3100` (with `derivedFields` mapping `trace_id` to X-Ray)
  - [x] X-Ray datasource → AWS X-Ray (using local dummy credentials for daemon mode)
- [x] `grafana/provisioning/dashboards/dashboards.yaml` — point to `grafana/dashboard-definitions/`
- [x] `grafana/dashboard-definitions/overview.json` — Main dashboard with panels:
  - [x] Request rate (Prometheus)
  - [x] `active_simulated_users` Gauge (Prometheus)
  - [x] Log stream panel (Loki) — filterable by level

**Done when:** Grafana starts, all datasources show green, and the overview dashboard renders with data. ✅ Configured (Validation occurs in Step 7).

---

### Step 6 — Locust Load Test (`locust/`)
**Brief:** Create a background traffic generator to simulate real user load, ensuring the dashboards always display live telemetry data.

- [x] `locust/locustfile.py`:
  - [x] `HttpUser` with tasks hitting `GET /items`, `GET /items/{id}` at varying weights
  - [x] A low-frequency task hitting `GET /crash` (to generate error traces)
  - [x] Wait time: `between(1, 3)` seconds
- [x] `locust/Dockerfile`
- [x] Add `locust` service to `docker-compose.yml` under `--profile load`

**Done when:** Building the locust image passes. ✅ Verified.

---

### Step 7 — Phase 1 Validation ✅
**Brief:** Prove the local pipeline works end-to-end: traffic flows from Locust → App → ADOT → Backends → Grafana, and logs correlate with traces.

- [x] `docker compose up` — all 6 core services start and stay healthy
- [x] `GET /health` → 200
- [x] `GET /crash` → 500 with stack trace in Loki logs
- [x] Locust started → request rate panel in Grafana shows a spike
- [x] Loki log panel shows ERROR entries from `/crash`
- [x] X-Ray trace visible for a `/crash` request
- [x] Log entry in Loki links to its X-Ray trace (Log-to-Trace correlation)

**Phase 1 is complete when all validation steps above pass.** ✅ Verified locally.

---

## Phase 2 — AWS Deployment (Terraform + ECS)

> Start Phase 2 only after Phase 1 validation is complete.
> Update `AGENTS.md` Current Phase to Phase 2 before starting.

---

### Step 8 — Local AWS Auth & Terraform State Bootstrap
**Brief:** Prepare the AWS environment for Infrastructure-as-Code (IaC) by establishing remote state storage in S3 and state locking in DynamoDB.

- [x] Ensure local AWS authentication is active (e.g., `aws sso login` or valid `~/.aws/credentials`)
- [x] Create S3 bucket for TF state (manually or via a bootstrap script) — versioning enabled
- [x] Create DynamoDB table for state locking (`LockID` string key)
- [x] `terraform/backend.tf` — configure S3 backend with bucket/key/region/dynamodb_table

**Done when:** `bootstrap-state.sh` is written and `main.tf` contains the backend block. ✅ Verified.

---

### Step 9 — Core AWS Infrastructure (`terraform/`)
**Brief:** Provision the foundational AWS networking (VPC), container orchestration (ECS Cluster), and registry (ECR) needed to host the platform.

- [x] `terraform/variables.tf` — `aws_region`, `project_name`, `environment`
- [x] `terraform/vpc.tf` — VPC, public/private subnets, NAT Gateway, Internet Gateway
- [x] `terraform/ecs.tf` — ECS Cluster (Fargate)
- [x] `terraform/ecr.tf` — ECR repository for the FastAPI app image
- [x] `terraform/iam.tf` — ECS task execution role and task role with least-privilege policies
- [x] `terraform/security_groups.tf` — SGs for each ECS service

**Done when:** `terraform plan` shows expected resources with no errors. ✅ Validated locally.

---

### Step 10 — Observability Infrastructure
**Brief:** Create the managed backend services (Managed Prometheus, S3 for Loki logs) and store their connection secrets securely in SSM Parameter Store.

- [ ] `terraform/amp.tf` — Amazon Managed Prometheus workspace; output remote write URL
- [ ] `terraform/s3.tf` — S3 bucket for Loki chunk storage; versioning + lifecycle rules
- [ ] `terraform/ssm.tf` — SSM parameters for AMP URL, Loki S3 bucket name, Grafana credentials

**Done when:** `terraform apply` provisions AMP workspace and S3 bucket; SSM parameters created.

---

### Step 11 — ECS Services
**Brief:** Define and deploy the actual containerized applications to ECS Fargate, reusing the same Docker images and configuration structures built in Phase 1.

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
**Brief:** Automate the build and deployment process so that pushes to the repository automatically update the AWS infrastructure and application code.

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
**Brief:** Confirm the production-grade AWS deployment is fully operational, proving that telemetry flows correctly through the cloud infrastructure.

- [ ] Grafana ALB URL accessible in browser
- [ ] All Grafana datasources (AMP, Loki, X-Ray) show green
- [ ] Overview dashboard renders with live data from AWS
- [ ] Locust run (ad-hoc) creates a spike on the AMP-backed dashboard
- [ ] `/crash` endpoint produces a log in Loki + trace in X-Ray + they are correlated in Grafana
- [ ] `terraform destroy` tears everything down cleanly (S3/DynamoDB state persists)

**Phase 2 is complete when all validation steps above pass.**
