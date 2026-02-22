# ==============================================================================
# CloudWatch Log Group for App and ADOT
# ==============================================================================
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/ecs/${var.project_name}-app-${var.environment}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "adot_logs" {
  name              = "/ecs/${var.project_name}-adot-${var.environment}"
  retention_in_days = 7
}

# ==============================================================================
# ADOT Configuration (Stored in SSM to inject as AOT_CONFIG_CONTENT)
# ==============================================================================
resource "aws_ssm_parameter" "adot_config" {
  name        = "/${var.project_name}/${var.environment}/adot_config"
  description = "AWS-specific ADOT Collector configuration YAML"
  type        = "String"
  value       = <<EOF
extensions:
  sigv4auth:
    region: "$${AWS_REGION}"
    service: "aps"

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
  resourcedetection:
    detectors: [env, system, ecs]
    timeout: 2s
    override: false

exporters:
  prometheusremotewrite:
    endpoint: "$${AMP_REMOTE_WRITE_URL}"
    auth:
      authenticator: sigv4auth
  # otlphttp/loki sends logs to Loki's native OTLP endpoint (/otlp/v1/logs)
  # This requires Loki 3.0+ which we now run (grafana/loki:3.3.2)
  otlphttp/loki:
    endpoint: "http://$${LOKI_ENDPOINT}:3100/otlp"
    tls:
      insecure: true
  awsxray:
    region: "$${AWS_REGION}"

service:
  extensions: [sigv4auth]
  telemetry:
    metrics:
      level: detailed
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [resourcedetection, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [resourcedetection, batch]
      exporters: [otlphttp/loki]
    traces:
      receivers: [otlp]
      processors: [resourcedetection, batch]
      exporters: [awsxray]
EOF
}

# ==============================================================================
# ECS Task Definition (App + ADOT Sidecar)
# ==============================================================================
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-app-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        # Communicate to ADOT natively over localhost in the Fargate task
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://127.0.0.1:4317" },
        { name = "OTEL_RESOURCE_ATTRIBUTES", value = "service.name=enterprise-api,environment=${var.environment}" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "adot"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        { containerPort = 4317, hostPort = 4317, protocol = "tcp" },
        { containerPort = 4318, hostPort = 4318, protocol = "tcp" }
      ]
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        # Route logs to Loki using the Internal ALB DNS
        { name = "LOKI_ENDPOINT", value = aws_lb.internal.dns_name }
      ]
      secrets = [
        # Fetch the dynamically generated ADOT Config YAML from SSM
        { name = "AOT_CONFIG_CONTENT", valueFrom = aws_ssm_parameter.adot_config.arn },
        # Fetch the AMP remote write URL so ADOT's internal expansion can use "AMP_REMOTE_WRITE_URL" 
        { name = "AMP_REMOTE_WRITE_URL", valueFrom = aws_ssm_parameter.amp_url.arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.adot_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# ==============================================================================
# ECS Service
# ==============================================================================
resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-app-svc-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8000
  }
}
