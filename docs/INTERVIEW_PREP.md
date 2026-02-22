# Interview Prep: Enterprise OTel Observability Stack

> A comprehensive set of 50+ questions and answers for technical interviews.  
> Covers fundamentals → architecture decisions → implementation → AWS → production/maintenance.

---

## 🟢 Section 1: Fundamentals & Project Overview (Q1–Q12)

---

### Q1. What is this project and what problem does it solve?

**A:** This project is a production-grade, end-to-end observability platform for containerised applications. It solves the "black box" problem — when something goes wrong in a production system, you need to answer *what* happened (logs), *how bad* it was (metrics), and *where in the call chain* it broke (traces). The three pillars of observability are all wired into a single, coherent pipeline using OpenTelemetry as the unified collection layer.

The project has two phases:
- **Phase 1 (Local):** Full stack on Docker Compose — proves the pipeline works end-to-end on a laptop before spending money on AWS.
- **Phase 2 (AWS):** Same stack deployed to AWS via Terraform and GitHub Actions CI/CD — real managed services replace local simulators.

---

### Q2. What is the role of a web framework like FastAPI in an application?

**A:** FastAPI is the **Web Server** or **Application Layer**. Its job is to:
1.  **Listen for connections:** It stays running and listens on a specific port (like 8000) for incoming traffic.
2.  **Route requests:** It maps a URL (e.g., `/items`) to a specific piece of Python code.
3.  **Handle data:** It takes incoming information (like a user's ID) and formats the results to send back.

In this project, FastAPI is the **subject being measured**. Without an application, there are no logs to read, no metrics to count, and no traces to follow. It provides the "work" that we are observing.

---

### Q3. What are the "three pillars of observability" and how does this project cover all three?

**A:**

| Pillar | What it tells you | Implementation |
|---|---|---|
| **Metrics** | Numeric measurements over time (latency, error rate, request count) | FastAPI app emits via OTel SDK → ADOT → Prometheus (local) / AMP (AWS) |
| **Logs** | Timestamped text records of discrete events | Python `logging` bridged to OTel logger → ADOT → Loki (local + AWS) |
| **Traces** | End-to-end request journeys across service boundaries | OTel `TracerProvider` auto-instruments FastAPI → ADOT → X-Ray Daemon (local) / AWS X-Ray (AWS) |

All three signals flow through ADOT, and all three are visualised in Grafana with Log-to-Trace correlation.

---

### Q4. What is OpenTelemetry (OTel) and why was it chosen?

**A:** OpenTelemetry is a CNCF-hosted open standard and collection of APIs, SDKs, and tools for generating and collecting telemetry data (metrics, logs, traces). It was chosen for three reasons:

1. **Vendor-neutral:** The application speaks OTLP (OpenTelemetry Protocol) and has zero awareness of where data ends up. Switching backends (e.g., from Prometheus to Datadog) requires only a config change in the collector — no app code changes.
2. **All-in-one:** One SDK, one protocol for all three telemetry signals.
3. **AWS-native support:** AWS provides ADOT (AWS Distro for OpenTelemetry), a supported distribution with first-class exporters for AMP, X-Ray, and Loki.

---

### Q5. What is ADOT and what role does it play?

**A:** ADOT (AWS Distro for OpenTelemetry) is AWS's supported distribution of the OpenTelemetry Collector. Its role is as the **telemetry broker** — it sits between the application and the storage backends.

The collector follows a **Receiver → Processor → Exporter** pipeline:
- **Receiver:** OTLP — listens on port 4317 (gRPC) and 4318 (HTTP) for incoming telemetry from the app.
- **Processors:** `resourcedetection` (enriches telemetry with environment metadata like ECS task ID) and `batch` (buffers data before sending to reduce HTTP overhead).
- **Exporters:** Route each signal to its backend:
  - Metrics → `prometheusremotewrite` (local Prometheus or AMP)
  - Logs → `otlphttp/loki` (local) or `loki` exporter (AWS)
  - Traces → `awsxray`

This design means the app only has one dependency (the ADOT endpoint) and the rest is configuration.

---

### Q6. Walk me through the data flow from the FastAPI app to Grafana.

**A:**
1. A HTTP request hits the **FastAPI** app (e.g., `GET /items`).
2. `FastAPIInstrumentor.instrument_app(app)` automatically creates an OTel **trace span** for the request.
3. The `app_metrics.request_count.add(1, ...)` call increments a **metric counter**.
4. Any `logging.info(...)` calls are bridged to the OTel **LoggerProvider** via `LoggingHandler`.
5. The OTel SDK exports all three signals to `OTEL_EXPORTER_OTLP_ENDPOINT` (the ADOT sidecar) over gRPC.
6. **ADOT** receives the signals, enriches them with resource attributes, batches them, and fans them out to three backends.
7. Metrics land in **Prometheus** (local) or **AMP** (AWS).
8. Logs land in **Loki** (backed by MinIO locally, or S3 on AWS).
9. Traces land in the **X-Ray Daemon** (local) or **AWS X-Ray** (AWS).
10. **Grafana** queries all three backends and displays them in dashboards.

---

### Q7. What is the `OTEL_RESOURCE_ATTRIBUTES` environment variable used for?

**A:** `OTEL_RESOURCE_ATTRIBUTES` is a standard OTel environment variable that injects key-value labels into every piece of telemetry emitted by the SDK. The most important one is `service.name`, which Loki uses as a log stream label and X-Ray uses to group traces.

In this project, it's set to:
```
service.name=enterprise-api,environment=dev
```

This means every metric, log, and trace automatically carries these labels, making it trivial to filter in Grafana (e.g., `{service_name="enterprise-api"} |= "ERROR"` in Loki).

---

### Q8. What is the "local-first" development strategy and why is it important?

**A:** Local-first means the full observability stack was built and validated on **Docker Compose before any AWS resources were provisioned**. This is critical because:

1. **Cost control** — debugging a misconfigured ADOT pipeline on AWS costs money (ECS task minutes, data transfer). Debugging it on Docker Desktop costs $0.
2. **Speed** — iterating on `adot/config.yaml` with a simple `docker-compose restart adot` takes 10 seconds; doing the same on ECS takes 2–3 minutes.
3. **Confidence** — when the AWS deployment behaves differently from local, you know the issue is the AWS environment (IAM, networking, endpoints), not the application or OTel config.

The key design principle: the Docker Compose stack is a **faithful simulation** of AWS — same ADOT config structure, same Grafana dashboard JSON, same app image. Moving to AWS is a config-endpoint swap, not a rewrite.

---

### Q9. What services run in the Docker Compose stack?

**A:** The `docker-compose.yml` defines 9 services:

| # | Service | Purpose |
|---|---|---|
| 1 | `app` | FastAPI application with OTel SDK |
| 2 | `adot` | Telemetry collector (Receiver/Processor/Exporter) |
| 3 | `prometheus` | Metrics time-series database |
| 4 | `minio` | S3-compatible object storage (Loki backend) |
| 5 | `minio-init` | One-shot helper to create the Loki S3 bucket |
| 6 | `loki` | Log aggregation database |
| 7 | `xray-daemon` | AWS X-Ray daemon (accepts trace data locally) |
| 8 | `grafana` | Visualisation layer |
| 9 | `locust` | Load generator (only runs with `--profile load`) |

Locust uses Docker Compose profiles so it doesn't start by default — you opt in with `docker-compose --profile load up`.

---

### Q10. How does Locust fit into the architecture?

**A:** Locust is the **traffic simulator**. A "living dashboard" is critical for a demo — if there's no traffic, all charts are flat lines. Locust continuously sends HTTP requests to the FastAPI app (`/items`, `/items/{id}`, `/crash`) with configurable concurrency and ramp-up rates.

Its traffic creates observable spikes in:
- Prometheus (request rate, latency histograms)
- Loki (log volume per level)
- X-Ray (trace throughput)

The Locust UI is available on port 8089, allowing you to adjust concurrency live and see the impact on Grafana dashboards in real time.

There's also a **background log generator** in the app that emits `INFO`, `WARNING`, and `ERROR` logs every few seconds, so log data flows even when Locust isn't running.

---

### Q11. Why was FastAPI chosen as the application framework?

**A:** FastAPI was selected for three primary reasons:
1. **Performance:** It's one of the fastest Python frameworks (benchmarking alongside Go and Node.js) due to its async nature, ensuring the app handles the "Living Demo" load without being a bottleneck.
2. **OTel Maturity:** There is a high-quality, community-supported instrumentation library (`opentelemetry-instrumentation-fastapi`) that provides excellent auto-instrumentation for traces and metrics with minimal code.
3. **OpenAPI Support:** It automatically generates Swagger documentation, allowing us to manually trigger endpoints (like `/crash`) to test the telemetry pipeline directly from the browser.

---

### Q12. What is the `/crash` endpoint and why does it exist?

**A:** `GET /crash` is an intentionally broken endpoint that calls `raise RuntimeError("Intentional crash...")`. It exists to demonstrate **Log-to-Trace correlation** in Grafana.

When it's called:
1. An `ERROR` log is emitted to Loki with the exception stack trace.
2. A trace span is created in X-Ray, marked as an error.
3. Both the log and the trace carry the same `trace_id` in their metadata.
4. In Grafana, you can click the trace ID in a Loki log line and jump directly to the corresponding X-Ray trace — this is the "observability loop" in action.

This directly demonstrates a real-world debugging workflow: *see an error in logs → find the trace → identify where the latency or exception occurred.*

---

## 🟡 Section 2: Architecture & Design Decisions (Q11–Q22)

---

### Q14. Why ADOT instead of running separate agents per signal (e.g., Fluent Bit + Prometheus Node Exporter)?

**A:** Running separate agents per signal creates operational sprawl:
- Each agent has its own configuration, upgrade path, and failure mode.
- Each agent adds a sidecar container, consuming CPU and memory.
- Correlating signals from separate agents is harder because they don't share a common data model.

ADOT provides a **single binary** that handles all three signals using the OTel data model throughout. The collector pattern also gives a single point to apply transformations (processors) uniformly to all signals. This was captured as **ADR-001**.

---

### Q15. Why AWS X-Ray for tracing instead of Grafana Tempo?

**A:** The decision (ADR-002) came down to **operational overhead**:

- **X-Ray** is fully managed — zero infrastructure to run in AWS. ADOT exports to it natively. For local development, the `amazon/aws-xray-daemon` Docker container provides a compatible endpoint. There's no new service to operate in AWS.
- **Grafana Tempo** would require an additional ECS service with persistent storage, a Tempo configuration, and IAM permissions — all for a service that primarily adds TraceQL query syntax on top of what X-Ray already provides for this use case.

For a project where the value is the **telemetry pipeline**, not the trace query language, X-Ray is the pragmatic choice.

---

### Q16. Why Grafana OSS on ECS instead of Amazon Managed Grafana (AMG)?

**A:** Amazon Managed Grafana (AMG) **mandates AWS IAM Identity Center (SSO)** as its authentication provider. Setting up Identity Center is a non-trivial prerequisite that involves creating a directory, configuring SAML, and managing AWS Organizations — all completely unrelated to observability.

Grafana OSS avoids this entirely. It uses a simple admin password (`GF_SECURITY_ADMIN_PASSWORD`) and provides identical dashboard and panel functionality. Critically, the same Grafana dashboard JSON files work identically in both local OSS and the AWS OSS container. This was ADR-003.

---

### Q17. Explain the two IAM roles used by ECS tasks. What is the difference between the Task Execution Role and the Task Role?

**A:** These two roles serve fundamentally different purposes:

**ECS Task Execution Role** (`ecs-exec-role-dev`):
- Used by the **ECS agent** (the AWS infrastructure), not your containers.
- Needed to: pull container images from ECR, fetch secrets from SSM Parameter Store, write container stdout/stderr to CloudWatch Logs.
- Has: `AmazonECSTaskExecutionRolePolicy` (managed) + custom `ssm:GetParameter` policy.

**ECS Task Role** (`ecs-task-role-dev`):
- Used by the **containers themselves** at runtime.
- The ADOT collector needs this role to call AWS APIs.
- Has: `AWSXrayWriteOnlyAccess` (to write traces), `AmazonPrometheusRemoteWriteAccess` (to push metrics to AMP), and S3 permissions (for Loki chunk storage).

A good way to remember it: the Execution Role is for AWS launching your task; the Task Role is for your task calling AWS.

---

### Q18. Why is Terraform state stored in S3 + DynamoDB and not locally or in Terraform Cloud?

**A:** This was ADR-004. Three reasons:

1. **CI/CD requirement:** The GitHub Actions pipeline runs `terraform apply`. If state were local, the runner would have no state and Terraform would try to recreate all resources. Remote state in S3 is accessible from any runner.
2. **State locking:** DynamoDB provides optimistic locking — if two `terraform apply` runs start simultaneously (e.g., two PRs merge at once), the second will wait rather than corrupt state.
3. **Simplicity over Terraform Cloud:** Terraform Cloud adds external authentication (API tokens). S3 + DynamoDB is native AWS, already within the same account, and free/near-free at this scale.

The `bootstrap-state.sh` script creates the S3 bucket and DynamoDB table as a one-time prerequisite before the first `terraform init`.

---

### Q19. Why SSM Parameter Store over AWS Secrets Manager for credentials?

**A:** ADR-005: **Cost and feature fit.** SSM Parameter Store Standard tier is free. AWS Secrets Manager costs $0.40/secret/month plus API call charges.

SSM is natively integrated with ECS Task Definitions via the `secrets` array in container definitions — the ECS agent fetches the value at task launch and injects it as an environment variable. No application code changes needed.

Secrets Manager's additional features (automatic rotation, cross-account access, binary secrets) are unnecessary here. The AMP remote write URL and ADOT config YAML are relatively static values that don't need rotation.

---

### Q20. Walk me through how the ADOT config changes between Phase 1 (local) and Phase 2 (AWS).

**A:** The pipeline *structure* is identical — same receivers, same processors, same three pipelines. Only the **exporter endpoints and authentication** change:

| Item | Phase 1 (Local) | Phase 2 (AWS) |
|---|---|---|
| Metrics exporter | `http://prometheus:9090/api/v1/write` | `${AMP_REMOTE_WRITE_URL}` + SigV4 auth |
| Logs exporter | `otlphttp/loki` → `http://loki:3100/otlp` | `loki` exporter → `http://{LOKI_ENDPOINT}:3100/loki/api/v1/push` |
| Traces exporter | `awsxray` with `local_mode: true` | `awsxray` with real AWS credentials via Task Role |
| Resource detectors | `[env, system]` | `[env, system, ecs]` — adds ECS task metadata |
| Extensions | None | `sigv4auth` — signs AMP requests with AWS SigV4 |

In Phase 2, the ADOT config YAML is stored as an SSM Parameter and injected via the `AOT_CONFIG_CONTENT` environment variable, which ADOT reads natively.

---

### Q21. What is the SigV4 authentication extension in the AWS ADOT config and why is it needed?

**A:** Amazon Managed Prometheus (AMP) is an AWS-secured service — it doesn't accept anonymous HTTP requests. Every `remote_write` call to AMP must be **signed with AWS SigV4** (the same signing mechanism used by all AWS API calls).

The ADOT `sigv4auth` extension automatically signs outgoing HTTP requests using the credentials available in the task's IAM role (the Task Role). The flow is:
1. ADOT's `prometheusremotewrite` exporter prepares a `remote_write` HTTP request.
2. The `sigv4auth` extension intercepts it, adds the `Authorization: AWS4-HMAC-SHA256 ...` header using the ECS task's [IMDS credentials](https://docs.aws.amazon.com/AmazonECS/latest/userguide/task-iam-roles.html).
3. AMP verifies the signature and accepts (or rejects) the write.

Without this, every `remote_write` attempt would return a 403 Forbidden.

---

### Q22. What is the ADOT sidecar pattern on ECS and how does it work?

**A:** In ECS Fargate, a **Task Definition** can contain multiple containers that share the same task lifecycle, network namespace, and (optionally) storage.

In this project, the App Task Definition has **two containers** sharing a single Fargate task:
- `app` container: FastAPI application
- `adot` container: ADOT collector

Because they share a network namespace, the app connects to ADOT using `http://127.0.0.1:4317` — **localhost**, not a DNS name. This is key because it means:
- No service discovery complexity for the app-to-collector link.
- ADOT is guaranteed to start in the same task as the app.
- If ADOT dies, the task restarts both containers together (both are `essential: true`).

The sidecar pattern is an ECS best practice for this use case because it tightly couples the collector to the application lifecycle.

---

### Q23. How are Grafana dashboards and datasources provisioned "as code"?

**A:** Grafana supports **provisioning via YAML files** that are loaded at startup. This project uses two provisioning directories:

**Datasources** (`grafana/provisioning/datasources/`): YAML files that define the Prometheus, Loki, and X-Ray datasource connections. Grafana reads these on start and creates the datasources automatically — no manual UI clicking.

**Dashboards** (`grafana/provisioning/dashboards/`): A YAML file that tells Grafana *where* to find dashboard JSON files. The actual dashboard definitions live in `grafana/dashboard-definitions/` as exported JSON.

These directories are mounted as read-only volumes:
```yaml
volumes:
  - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
  - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
  - ./grafana/dashboard-definitions:/var/lib/grafana/dashboards:ro
```

The result: run `docker-compose up` and Grafana is fully configured with dashboards and datasources — zero manual setup. The same JSON files are deployed to the AWS ECS Grafana container.

---

### Q24. Why use ECS Fargate instead of EC2 or EKS?

**A:** ADR-007: **Fargate eliminates server management** while providing a near 1:1 mapping from Docker Compose services to ECS Task Definitions.

- **vs EC2:** EC2 requires managing AMIs, patching operating systems, autoscaling groups. For containers, this is undifferentiated heavy lifting.
- **vs EKS (Kubernetes):** EKS adds networking complexity (CNI plugins, kube-proxy), control plane management, and YAML surface area that's completely disproportionate to running 3 simple containers. Kubernetes shines at scale; it's overkill for a 3-service observability demo.
- **Fargate:** No servers to manage, built-in sidecar support, native IAM task roles, and VPC networking with `awsvpc` mode. The task definitions directly mirror the `docker-compose.yml` service definitions.

---

### Q25. What are the two VPC subnet tiers, and why are the ECS tasks in private subnets?

**A:** The VPC (created by the AWS VPC Terraform module) has two subnet tiers:
- **Public subnets:** Host the Application Load Balancer (ALB). These subnets have a route to the Internet Gateway, so the ALB can receive traffic from the public internet.
- **Private subnets:** Host all ECS tasks (App+ADOT, Loki, Grafana). These subnets have no direct internet route.

ECS tasks are in private subnets for **security**: the containers should never be directly reachable from the internet. All inbound traffic routes through the ALB. A **NAT Gateway** in the public subnets allows ECS tasks in private subnets to initiate *outbound* connections (e.g., pulling ECR images, calling AMP and X-Ray APIs) without being publicly addressable.

The NAT Gateway is the main ongoing cost driver (approximately $5/month) because it charges per hour plus per GB of processed data.

---

## 🟠 Section 3: Implementation Deep Dives (Q23–Q35)

---

### Q26. How exactly is the FastAPI app instrumented for all three signals?

**A:** The `setup_telemetry()` function initialises three OTel providers at app startup:

```python
# Traces
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(tracer_provider)

# Metrics
reader = PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=15_000)
meter_provider = MeterProvider(resource=resource, metric_readers=[reader])
otel_metrics.set_meter_provider(meter_provider)

# Logs
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
set_logger_provider(logger_provider)
otel_handler = LoggingHandler(level=logging.DEBUG, logger_provider=logger_provider)
logging.basicConfig(level=logging.DEBUG, handlers=[otel_handler])
```

The key insight for logs: `LoggingHandler` **bridges** Python's standard library `logging` module to the OTel `LoggerProvider`. This means any code using `logging.info(...)` automatically emits to Loki — no OTel SDK calls needed in application code. Traces are further auto-instrumented by `FastAPIInstrumentor.instrument_app(app)`, which patches all route handlers.

---

### Q27. What is `BatchSpanProcessor` and why is it used instead of `SimpleSpanProcessor`?

**A:** `BatchSpanProcessor` buffers spans in memory and flushes them in batches to the exporter. `SimpleSpanProcessor` exports each span synchronously, one at a time, on the request thread.

For a production web server:
- `SimpleSpanProcessor` would add latency to **every request** — your route handler can't finish until the trace export completes.
- `BatchSpanProcessor` exports asynchronously in a background thread, keeping request latency unaffected.

Similarly, `BatchLogRecordProcessor` and `PeriodicExportingMetricReader` handle logs and metrics asynchronously. The `batch` processor in ADOT does a second level of batching on the collector side before sending to backends.

---

### Q28. What are the two custom metric instruments defined in `metrics.py`?

**A:**

1. **`http_request_count` (Counter):** Incremented every time a route handler is called. Uses `add(1, {"endpoint": "/items", "method": "GET"})` with dimensional labels so you can filter by endpoint or method in Grafana. A Counter only ever goes up; it's appropriate for "total requests received."

2. **`active_simulated_users` (ObservableGauge):** A gauge whose value is read by the SDK at each collection interval (every 15 seconds). Its value is set by the background log generator thread via `set_active_users()`. An ObservableGauge is appropriate for point-in-time values that can go up OR down (like current user count or CPU usage).

The `configure(meter)` function is called once after `MeterProvider` is initialised, ensuring instruments are bound to the correct meter.

---

### Q29. How does the Terraform Terraform state bootstrapping work?

**A:** Terraform's S3 backend for remote state requires the S3 bucket and DynamoDB table to exist **before** `terraform init` can run — a classic chicken-and-egg problem.

The `bootstrap-state.sh` script solves this:
1. Creates the S3 bucket with versioning and encryption enabled using raw `aws s3api` CLI commands.
2. Creates the DynamoDB table (`LockID` as the hash key) with On-Demand billing.
3. This runs *once* as a manual prerequisite step.

After that, `terraform init` can reference the backend:
```hcl
backend "s3" {
  bucket         = "enterprise-otel-tf-state"
  key            = "dev/terraform.tfstate"
  region         = "ap-southeast-2"
  dynamodb_table = "enterprise-otel-tf-lock"
}
```

All subsequent `terraform apply` runs in CI/CD use this remote state automatically.

---

### Q30. How does the GitHub Actions CI/CD pipeline work?

**A:** The pipeline (`.github/workflows/`) is triggered on pushes to `main`. It runs two sequential jobs:

**Job 1: Build & Push**
1. Checkout the repository
2. Configure AWS credentials using OIDC (no stored access keys — uses `iam_github.tf` which creates a trust relationship between GitHub and AWS)
3. Log in to ECR
4. Build the FastAPI Docker image
5. Tag and push to the ECR repository

**Job 2: Deploy (runs after Job 1)**
1. Configure Terraform with the S3 backend
2. Run `terraform plan`
3. Run `terraform apply -auto-approve`

The ECS service is updated via Terraform's `aws_ecs_service` resource detecting the new task definition (with the updated ECR image tag). ECS performs a rolling deployment by default — new tasks start before old tasks stop.

---

### Q31. How are secrets passed to ECS containers? Walk through a specific example.

**A:** Using the `AOT_CONFIG_CONTENT` secret as an example:

**Step 1 — Store in SSM (via Terraform):**
```hcl
resource "aws_ssm_parameter" "adot_config" {
  name  = "/enterprise-otel/dev/adot_config"
  type  = "String"
  value = <<EOF ... YAML config ... EOF
}
```

**Step 2 — Reference in Task Definition:**
```json
{
  "secrets": [
    { "name": "AOT_CONFIG_CONTENT", "valueFrom": "arn:aws:ssm:ap-southeast-2:...:parameter/enterprise-otel/dev/adot_config" }
  ]
}
```

**Step 3 — At Task Launch:**
The ECS agent (using the Task Execution Role) calls `ssm:GetParameter`, fetches the value, and injects it as `AOT_CONFIG_CONTENT` into the container's environment. The container never needs to know about SSM.

**Step 4 — ADOT reads it:**
ADOT natively reads its configuration from `AOT_CONFIG_CONTENT` when set, overriding any config file path.

---

### Q32. How does Loki store log data, and what changes between local and AWS?

**A:** Loki stores data in two parts: **chunks** (compressed log data) and **indexes** (metadata for querying). Both need an object storage backend.

**Local (Phase 1):**
- **MinIO** simulates AWS S3. `minio/minio` runs as a container.
- `minio-init` is an ephemeral helper container that runs once to create the `loki-data` bucket using the MinIO client (`mc`).
- Loki is configured with `filesystem` or S3-compatible backend pointing to MinIO.

**AWS (Phase 2):**
- MinIO is replaced by a real **Amazon S3 bucket** managed by `s3.tf`.
- Loki on ECS uses the S3 backend. The Task Role has `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject` permissions on the Loki bucket.
- No MinIO, no minio-init — S3 is always available, always durable.

---

### Q33. How does Prometheus receive metrics from ADOT?

**A:** Via **Remote Write**. Standard Prometheus works by *pulling* (scraping) metrics from targets on a schedule. However, ADOT is a *push*-based system — it sends data to backends.

Prometheus supports receiving pushed metrics through its Remote Write API (`/api/v1/write`). In the Docker Compose setup, Prometheus is started with the `--web.enable-remote-write-receiver` flag:

```yaml
command:
  - '--config.file=/etc/prometheus/prometheus.yml'
  - '--web.enable-remote-write-receiver'
```

ADOT's `prometheusremotewrite` exporter then pushes metrics to `http://prometheus:9090/api/v1/write`. In AWS, the same exporter pushes to AMP's remote write URL, which is the managed equivalent of this endpoint.

---

### Q34. What is the `resourcedetection` processor in ADOT and what does it add in AWS?

**A:** The `resourcedetection` processor automatically enriches telemetry with metadata about the environment where the collector is running.

**Phase 1 (local) — detectors `[env, system]`:**
- `env`: Reads `OTEL_RESOURCE_ATTRIBUTES` — adds `service.name`, `environment`, etc.
- `system`: Adds host metadata (hostname, OS type).

**Phase 2 (AWS) — detectors `[env, system, ecs]`:**
- `ecs`: **Additionally** adds ECS task metadata: `aws.ecs.task.arn`, `aws.ecs.task.family`, `aws.ecs.cluster.arn`, `cloud.availability_zone`, etc.

This is critical for AWS because it automatically attaches the ECS task context to every metric, log, and trace — allowing you to filter Grafana by cluster, task family, or AZ without any manual instrumentation.

---

### Q35. How do you run the load test and what does it generate?

**A:** Start Locust with the load profile:
```bash
docker-compose --profile load up locust
```

Access the Locust Web UI at `http://localhost:8089`. Configure:
- **Number of users:** The peak concurrency (e.g., 50)
- **Ramp-up:** Users per second added until peak is reached (e.g., 5/sec)

The `locust/locustfile.py` defines tasks that hit:
- `GET /items` — generates metrics, a log line, and a trace
- `GET /items/{id}` — with random IDs 1-150 (causes 404s for IDs > 100, generating error traces)
- `GET /crash` — intentionally crashes to generate error logs and failed traces

Within 30 seconds, you should see clear traffic spikes on the Grafana request rate panel.

---

### Q36. Explain the `loki-config.yaml` and how Loki is configured for S3/MinIO storage.

**A:** The `loki-config.yaml` configures Loki's storage backend. The key section is `storage_config`:

```yaml
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: s3
      schema: v13

storage_config:
  tsdb_shipper:
    active_index_directory: /var/loki/tsdb-index
    cache_location: /var/loki/tsdb-cache
  aws:
    s3: http://minio:9000/loki-data
    s3forcepathstyle: true
    bucketnames: loki-data
    access_key_id: ${MINIO_ROOT_USER}
    secret_access_key: ${MINIO_ROOT_PASSWORD}
```

`s3forcepathstyle: true` is critical for MinIO — AWS S3 uses virtual-hosted-style (`bucket.s3.amazonaws.com`) while MinIO uses path-style (`minio:9000/bucket`). In AWS, this flag is removed and the endpoint is the real S3 URL.

---

### Q37. What security groups are defined and what do they control?

**A:** `security_groups.tf` defines two key groups:

**ALB Security Group (`aws_security_group.alb`):**
- Inbound: Allow port 80 (HTTP) from `0.0.0.0/0` — internet-facing, allows anyone to reach the ALB.
- Outbound: Allow all to ECS tasks.

**ECS Tasks Security Group (`aws_security_group.ecs_tasks`):**
- Inbound: Allow traffic only from the ALB security group — ECS tasks are NOT reachable from the internet, only via the ALB.
- Inbound: Allow inter-service traffic within the VPC CIDR block (so Grafana can reach Loki, ADOT can reach Loki, etc.).
- Outbound: Allow all — tasks need outbound to call AMP, X-Ray, ECR, and SSM.

This enforces the principle of least privilege: the only way into an ECS task from outside the VPC is via the ALB.

---

### Q38. What does the `aws_ecs_task_definition` resource look like for the App+ADOT task?

**A:** The task definition (`ecs_app.tf`) provisions:
- **Family:** `enterprise-otel-app-dev`
- **Launch type:** FARGATE (requires `awsvpc` network mode)
- **Total resources:** 512 CPU units (0.5 vCPU), 1024 MB memory
- **Two containers:**
  - `app`: 256 CPU / 512 MB, essential, `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317` (localhost because sidecar shares network namespace)
  - `adot`: 256 CPU / 512 MB, essential, reads `AOT_CONFIG_CONTENT` and `AMP_REMOTE_WRITE_URL` from SSM secrets
- **Two IAM roles:** `execution_role_arn` (ECS agent) and `task_role_arn` (containers at runtime)
- **CloudWatch log groups** for both containers (`/ecs/enterprise-otel-app-dev` and `/ecs/enterprise-otel-adot-dev`)

If either container fails health checks, ECS considers the task unhealthy and replaces it (both containers restart because both are `essential: true`).

---

## 🔴 Section 4: AWS Services Deep Dive (Q36–Q43)

---

### Q39. What is Amazon Managed Prometheus (AMP) and how does it differ from self-hosted Prometheus?

**A:** AMP is a fully managed, HA, Prometheus-compatible metrics service. Key differences:

| | Self-hosted Prometheus | AMP |
|---|---|---|
| Infrastructure | You manage the EC2/container | AWS manages it |
| High Availability | Requires separate Thanos/Cortex | Built-in |
| Storage | Local disk (lossy if container dies) | Durable, managed storage |
| Scaling | Manual capacity planning | Auto-scales |
| Authentication | Network-level only | SigV4 (IAM-based) |
| Query API | Standard PromQL over HTTP | Same PromQL, but requires SigV4 auth |
| Cost | Fargate compute cost | Per-sample ingest + per-query |

For this project, AMP is a **drop-in replacement** for the local Prometheus container. The query endpoint is configured as a Grafana datasource with SigV4 auth enabled.

---

### Q40. What is AWS X-Ray and how does it integrate with this stack?

**A:** AWS X-Ray is a fully managed distributed tracing service. It stores trace segments and provides a service map, trace timeline, and anomaly detection.

Integration in this stack:
1. ADOT's `awsxray` exporter converts OTel spans to X-Ray's segment format and HTTP POSTs them to the X-Ray API.
2. In local development, the `amazon/aws-xray-daemon` Docker container accepts the same API on port 2000/UDP and stores traces in memory (no real AWS calls because `local_mode: true`).
3. In AWS, ADOT uses the task's IAM role (`AWSXrayWriteOnlyAccess`) to write directly to the X-Ray service.

Grafana can query X-Ray via the **AWS X-Ray datasource plugin**, allowing you to view trace timelines and service maps directly in Grafana rather than switching to the AWS console.

---

### Q41. What is ECR and what Terraform resources manage it?

**A:** Amazon Elastic Container Registry (ECR) is AWS's managed Docker registry. It stores the FastAPI application's container image.

In `ecr.tf`:
```hcl
resource "aws_ecr_repository" "app" {
  name                 = "enterprise-otel-app"
  image_tag_mutability = "MUTABLE"
}
```

`MUTABLE` tags are used so the CI/CD pipeline can push the same `:latest` tag on every build — ECS then pulls the new image on the next task deployment. For stricter environments, `IMMUTABLE` with versioned tags is preferred.

The GitHub Actions pipeline uses OIDC to authenticate to ECR without storing long-lived AWS access keys in GitHub Secrets.

---

### Q42. What is OIDC authentication for GitHub Actions and why is it used?

**A:** OIDC (OpenID Connect) allows GitHub Actions to obtain short-lived AWS credentials dynamically, without storing any long-lived `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets in GitHub.

The mechanism (configured via `iam_github.tf`):
1. Terraform creates an IAM OIDC Identity Provider for `token.actions.githubusercontent.com`.
2. Terraform creates an IAM Role with a trust policy allowing GitHub Actions jobs (from this specific repository and branch) to assume it via `sts:AssumeRoleWithWebIdentity`.
3. At runtime, GitHub Actions calls AWS STS with a GitHub-issued JWT token; STS validates it against the registered OIDC provider and returns temporary credentials.

Benefits: No secret rotation needed, credentials expire after 15 minutes, and the trust is scoped to a specific GitHub org/repo/branch.

---

### Q43. What is an Application Load Balancer (ALB) and how is it configured here?

**A:** The ALB (`alb.tf`) is the internet-facing entry point to the stack. It accepts HTTP traffic and routes to ECS services.

Key configuration:
- **External ALB:** Routes public traffic to the `app` service (port 80 → Fargate task port 8000).
- **Internal ALB:** Handles inter-service communication within the VPC. ADOT uses the internal ALB DNS name (`aws_lb.internal.dns_name`) as the Loki endpoint, and Grafana uses it to reach Loki and Prometheus/AMP.

Target groups with **health checks** ensure traffic only routes to healthy ECS task instances. The health check hits `GET /health` on port 8000, which returns `{"status": "ok"}`.

---

### Q44. What happens end-to-end when you run `terraform apply` for the first time?

**A:** Terraform builds the full dependency graph and creates resources in parallel where possible, sequentially where there are dependencies:

1. **VPC module** — Creates VPC, public/private subnets, NAT Gateway, Internet Gateway, route tables.
2. **Security Groups** — ALB SG, ECS Tasks SG (depends on VPC).
3. **ECR** — Creates the image repository.
4. **ECS Cluster** — Empty cluster (depends on nothing).
5. **IAM Roles** — Execution role and task role (depends on nothing).
6. **S3 + DynamoDB** — Loki storage + Terraform state (already exist from bootstrap).
7. **AMP Workspace** — Creates the Prometheus workspace, outputs the remote write URL.
8. **SSM Parameters** — Stores ADOT config YAML and AMP URL (depends on AMP).
9. **ALBs + Target Groups** — Depends on VPC/SGs.
10. **ECS Task Definitions** — References ECR, SSM, IAM, CloudWatch log groups.
11. **ECS Services** — Starts tasks (depends on Task Definitions, ALBs, VPC).

The first `apply` can take 10–15 minutes due to NAT Gateway and AMP workspace provisioning times.

---

### Q45. How do you troubleshoot an ECS task that fails to start?

**A:** A systematic approach:

1. **Check ECS Event logs:** In the AWS console → ECS → Cluster → Service → Events tab. Shows messages like "task stopped because container exited with code 1."
2. **Check CloudWatch Logs:** `/ecs/enterprise-otel-app-dev` and `/ecs/enterprise-otel-adot-dev` contain stdout/stderr. Most startup failures print to stderr.
3. **Check Stopped Tasks:** ECS keeps recent stopped tasks with a "Stopped Reason" — common ones: `CannotPullContainerError` (ECR permission, image doesn't exist), `ResourceInitializationError` (can't fetch SSM secret — check IAM), `Essential container exited` (application crash on startup).
4. **Verify IAM:** The most common cause. Check that the Task Execution Role has SSM permissions and the Task Role has XRay/AMP permissions for the correct region.
5. **Check Security Groups:** If the container starts but can't reach AMP, X-Ray, or ECR, the security group outbound rules may be blocking AWS API calls.
6. **Test locally:** `docker-compose up` with the same environment variables to reproduce startup failures cheaply.

---

### Q46. What happens if the ADOT sidecar crashes while the app container is still running?

**A:** Both containers in the task definition have `essential: true`. This means if **either container exits** (for any reason), ECS considers the entire task failed and terminates **all** containers in the task, then starts a replacement task.

This is intentional: if ADOT is down, the app is still generating telemetry that goes nowhere — it would be silently losing observability data. Failing fast and restarting ensures the entire task recovers together.

The OTel SDK handles brief ADOT unavailability gracefully: `BatchSpanProcessor` buffers spans in memory and retries exports. But an extended ADOT outage would cause buffer overflow and dropped telemetry.

---

## 🔴 Section 5: Maintenance, Operations, and Production (Q44–Q50)

---

### Q47. How would you update a Grafana dashboard in production?

**A:** The dashboards-as-code approach means the update flow is:

1. Export the updated dashboard JSON from Grafana UI (Share → Export → JSON).
2. Replace the file in `grafana/dashboard-definitions/`.
3. Commit and push to `main`.
4. GitHub Actions builds the new app image and runs `terraform apply`.
5. Terraform detects that the Grafana ECS task definition hasn't changed (dashboards are in the image or mounted), but if dashboards are provisioned via a mounted volume from S3 or ECS, they'll be refreshed.

**Important nuance:** In ECS Fargate, there are no host volumes. Grafana dashboards must either be:
- **Baked into the Grafana Docker image** (a custom `Dockerfile` `COPY` of the dashboard JSON), OR
- **Loaded from S3** using a Grafana plugin, OR
- **Applied via the Grafana API** at deploy time (a `curl` in a CI/CD step).

For this project, the dashboards are provisioned via mounted volumes in local (Docker Compose) and need to be handled via one of the above patterns for the ECS deployment.

---

### Q48. What is the cost-saving strategy when not actively using the AWS stack?

**A:** The `terraform destroy` approach (ADR cost optimization):

When the stack is not needed (nights, weekends):
```bash
terraform destroy
```

This tears down all compute (ECS services, ALBs, NAT Gateway — the main cost drivers) while **preserving:**
- **S3 bucket** for Terraform state (< $0.01/month)
- **DynamoDB table** for state lock (on-demand, effectively $0)
- **ECR images** (< $0.10/month for small images)

When needed again:
```bash
terraform apply
```

Rebuilds in ~10–15 minutes. Total cost drops from ~$30/month to ~$1–2/month for persistent storage.

For Fargate Spot (70% discount), update the ECS service to use `capacity_provider_strategy` with `FARGATE_SPOT` for non-critical services (Loki, Grafana) while keeping the App on `FARGATE` for stability.

---

### Q49. How would you add a new metric to the application?

**A:**

1. **Define the instrument in `app/metrics.py`:**
```python
# In configure(meter):
checkout_duration = meter.create_histogram(
    name="checkout_duration_seconds",
    description="Time taken to process checkout",
    unit="s",
)
```

2. **Record it in the route handler (`main.py`):**
```python
import time
start = time.time()
# ... business logic ...
app_metrics.checkout_duration.record(time.time() - start, {"status": "success"})
```

3. **Use it in Grafana:** Once data flows to Prometheus/AMP, query it with:
   ```promql
   histogram_quantile(0.95, rate(checkout_duration_seconds_bucket[5m]))
   ```

No ADOT config changes needed — all metrics flowing through the `otlp` receiver go through the metrics pipeline automatically.

---

### Q50. How would you scale the observability stack for a production microservices system?

**A:** The current stack is designed for a single service. For microservices at scale:

1. **Multiple application services:** Each service gets its own ADOT sidecar, all pointing to the same AMP and Loki backends. `service.name` differentiates them in queries.
2. **ADOT as a standalone gateway:** For higher volume, deploy a central ADOT collector as a separate ECS service (not a sidecar) that receives OTLP from all services, reducing per-task overhead.
3. **AMP scaling:** AMP auto-scales; no action needed. However, add recording rules and alerting rules to reduce query load on dashboards.
4. **Loki scaling:** Move from the single-binary Loki mode to Loki's **microservices mode** (separate distributor, ingester, querier components) for horizontal scaling.
5. **Grafana:** Add a load-balanced Grafana cluster with an external PostgreSQL backend for dashboard state.
6. **Alerting:** Add Grafana Alerting or Amazon Managed Grafana alerting rules that notify PagerDuty/Slack on SLO breaches.

---

### Q51. How do you verify the telemetry pipeline is actually working end-to-end?

**A:** A structured validation sequence:

**1. Check ADOT is receiving data:**
```bash
curl http://localhost:8888/metrics | grep otelcol_receiver_accepted_spans
```
If `accepted_spans` is incrementing, ADOT is receiving traces.

**2. Check ADOT is successfully exporting:**
```bash
curl http://localhost:8888/metrics | grep otelcol_exporter_sent_metric_points
```
Non-zero `sent_metric_points` means Prometheus/AMP is accepting metrics.

**3. Check Prometheus has data:**
Go to `http://localhost:9090` → Execute `http_request_count_total`. Should return results.

**4. Check Loki has logs:**
Go to Grafana → Explore → Loki datasource → run `{service_name="enterprise-api"}`. Should return log lines.

**5. End-to-end test:**
```bash
curl http://localhost:8000/crash
```
Then in Grafana, find the error log in Loki. Click the trace ID link. Verify it opens in X-Ray/Grafana Explore.

---

### Q52. What would you monitor to detect if the observability stack itself is having issues?

**A:** "Observing the observer" — ADOT exposes its own internal metrics on port 8888:

| Metric | What it signals |
|---|---|
| `otelcol_receiver_refused_spans` | App can't reach ADOT (network issue, ADOT down) |
| `otelcol_exporter_send_failed_metric_points` | Export to AMP is failing (IAM, network, AMP down) |
| `otelcol_exporter_send_failed_log_records` | Loki is unreachable or rejecting data |
| `otelcol_processor_batch_timeout_trigger_send` | Batch timeouts — data is flowing but slowly |
| `otelcol_process_memory_rss` | Memory pressure on the ADOT container |

In production, you'd scrape these metrics from ADOT into Prometheus itself and create an alert: "if `exporter_send_failed` > 0 for 5 minutes, alert the on-call engineer."

Additionally, monitor Fargate task restart counts via CloudWatch for ECS task stability signals.

---

### Q53. If you had to explain this project's business value to a non-technical executive, what would you say?

**A:** "This project solves one of the most expensive problems in software — **not knowing what's wrong when something breaks in production**.

Before observability, when your service has an incident, your engineers spend hours — sometimes days — blindly searching logs, guessing at causes, and hoping the next fix works. That downtime costs revenue, customer trust, and engineering time.

This platform gives engineers **three types of instant answers**:
- *What is broken?* — Metrics show request error rates and latency spiking in real time.
- *Why is it broken?* — Logs show the exact error message and context.
- *Where in the system is it broken?* — Traces show the complete request journey, pinpointing which service or database call caused the slowdown.

What makes this implementation stand out:
1. **It uses OpenTelemetry** — an open industry standard. Your engineers aren't locked into a vendor. If you want to switch from one monitoring tool to another, you change a config file, not your application code.
2. **It runs on AWS-managed services** — zero servers to patch, built-in high availability, ~$30/month for a continuous demo environment.
3. **It's built as code** — every dashboard, every data pipeline, every piece of infrastructure is version-controlled in Git. A new engineer can spin up a complete copy of the entire observability stack in under 15 minutes with a single command."

---

*Document created for interview preparation. Questions cover: project overview, architecture decisions (ADRs), OTel instrumentation, ADOT configuration, IAM and security, Terraform and IaC, ECS Fargate deployment, AWS managed services, CI/CD, and production operations.*
