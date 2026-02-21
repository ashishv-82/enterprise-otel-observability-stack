# ==============================================================================
# CloudWatch Log Group for Grafana
# ==============================================================================
resource "aws_cloudwatch_log_group" "grafana_logs" {
  name              = "/ecs/${var.project_name}-grafana-${var.environment}"
  retention_in_days = 7
}

# ==============================================================================
# Grafana Configuration (Stored in SSM)
# ==============================================================================
resource "aws_ssm_parameter" "grafana_dashboards_yaml" {
  name        = "/${var.project_name}/${var.environment}/grafana_dashboards_yaml"
  description = "Grafana Dashboards Provisioning YAML"
  type        = "String"
  value       = file("../grafana/provisioning/dashboards/dashboards.yaml")
}

resource "aws_ssm_parameter" "grafana_overview_json" {
  name        = "/${var.project_name}/${var.environment}/grafana_overview_json"
  description = "Grafana Overview Dashboard JSON"
  type        = "String"
  value       = file("../grafana/dashboard-definitions/overview.json")
}

resource "aws_ssm_parameter" "grafana_datasources" {
  name        = "/${var.project_name}/${var.environment}/grafana_datasources"
  description = "AWS-specific Grafana Datasources Provisioning YAML"
  type        = "String"
  value       = <<EOF
apiVersion: 1

datasources:
  # 1. Prometheus (Metrics) -> Amazon Managed Prometheus
  - name: Prometheus
    type: prometheus
    access: proxy
    url: $${AMP_WORKSPACE_URL}
    isDefault: true
    jsonData:
      sigV4Auth: true
      sigV4AuthType: default
      sigV4Region: $${AWS_REGION}

  # 2. Loki (Logs) -> Internal ECS Service
  - name: Loki
    type: loki
    access: proxy
    url: http://$${LOKI_ENDPOINT}:3100
    jsonData:
      derivedFields:
        - datasourceUid: xray
          matcherRegex: "trace_id=([a-zA-Z0-9]+)"
          name: TraceID
          url: "$$${__value.raw}"

  # 3. AWS X-Ray (Traces) -> Natively uses ECS Task Role
  - name: X-Ray
    uid: xray
    type: grafana-x-ray-datasource
    access: proxy
    jsonData:
      authType: default
      defaultRegion: $${AWS_REGION}
EOF
}

# ==============================================================================
# ECS Task Definition (Grafana)
# ==============================================================================
resource "aws_ecs_task_definition" "grafana" {
  family                   = "${var.project_name}-grafana-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = "grafana/grafana-oss:latest"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        { containerPort = 3000, hostPort = 3000, protocol = "tcp" }
      ]
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "LOKI_ENDPOINT", value = aws_lb.internal.dns_name },
        # AMP remote write URL resolves to `api/v1/remote_write`. Query URL is the workspace itself.
        { name = "AMP_WORKSPACE_URL", value = aws_prometheus_workspace.main.prometheus_endpoint }
      ]
      secrets = [
        { name = "GRAFANA_DATASOURCES_YAML", valueFrom = aws_ssm_parameter.grafana_datasources.arn },
        { name = "GRAFANA_DASHBOARDS_YAML", valueFrom = aws_ssm_parameter.grafana_dashboards_yaml.arn },
        { name = "GRAFANA_OVERVIEW_JSON", valueFrom = aws_ssm_parameter.grafana_overview_json.arn }
      ]
      # Intercept start to write provisioned files to disk
      entryPoint = ["/bin/sh", "-c"]
      command = [
        "mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards && echo \"$$GRAFANA_DATASOURCES_YAML\" > /etc/grafana/provisioning/datasources/datasources.yaml && echo \"$$GRAFANA_DASHBOARDS_YAML\" > /etc/grafana/provisioning/dashboards/dashboards.yaml && echo \"$$GRAFANA_OVERVIEW_JSON\" > /var/lib/grafana/dashboards/overview.json && exec /run.sh"
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.grafana_logs.name
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
resource "aws_ecs_service" "grafana" {
  name            = "${var.project_name}-grafana-svc-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }
}
