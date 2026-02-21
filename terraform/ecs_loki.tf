# ==============================================================================
# CloudWatch Log Group for Loki
# ==============================================================================
resource "aws_cloudwatch_log_group" "loki_logs" {
  name              = "/ecs/${var.project_name}-loki-${var.environment}"
  retention_in_days = 7
}

# ==============================================================================
# Loki Configuration (Stored in SSM)
# ==============================================================================
resource "aws_ssm_parameter" "loki_config" {
  name        = "/${var.project_name}/${var.environment}/loki_config"
  description = "AWS-specific Loki configuration YAML"
  type        = "String"
  value       = <<EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    s3:
      bucketnames: $${LOKI_S3_BUCKET}
      region: $${AWS_REGION}
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: loki_index_
        period: 24h

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 1h
  max_cache_freshness_per_query: 10m
EOF
}

# ==============================================================================
# ECS Task Definition (Loki)
# ==============================================================================
resource "aws_ecs_task_definition" "loki" {
  family                   = "${var.project_name}-loki-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name = "loki"
      # Using a specific versioned tag (Alpine-based) which has /bin/sh.
      # grafana/loki:latest is distroless and has no shell, making our init command impossible.
      image     = "grafana/loki:2.9.8"
      cpu       = 512
      memory    = 1024
      essential = true
      portMappings = [
        { containerPort = 3100, hostPort = 3100, protocol = "tcp" }
      ]
      environment = [
        { name = "AWS_REGION", value = var.aws_region }
      ]
      secrets = [
        # Fetch the dynamically generated Loki config and bucket name from SSM
        { name = "LOKI_CONFIG_CONTENT", valueFrom = aws_ssm_parameter.loki_config.arn },
        { name = "LOKI_S3_BUCKET", valueFrom = aws_ssm_parameter.loki_s3_bucket.arn }
      ]
      # Write the SSM-injected config to disk using printenv (avoids shell $$ escaping issues)
      entryPoint = ["/bin/sh", "-c"]
      command    = ["mkdir -p /etc/loki && printenv LOKI_CONFIG_CONTENT > /etc/loki/local-config.yaml && /usr/bin/loki -config.file=/etc/loki/local-config.yaml -config.expand-env=true"]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.loki_logs.name
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
resource "aws_ecs_service" "loki" {
  name            = "${var.project_name}-loki-svc-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.loki.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.loki.arn
    container_name   = "loki"
    container_port   = 3100
  }
}
