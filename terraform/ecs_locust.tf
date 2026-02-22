# ==============================================================================
# CloudWatch Log Group for Locust
# ==============================================================================
resource "aws_cloudwatch_log_group" "locust_logs" {
  name              = "/ecs/${var.project_name}-locust-${var.environment}"
  retention_in_days = 7
}

# ==============================================================================
# ECS Task Definition (Locust Load Generator)
# ==============================================================================
resource "aws_ecs_task_definition" "locust" {
  family                   = "${var.project_name}-locust-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "locust"
      image     = "${aws_ecr_repository.locust.repository_url}:latest"
      cpu       = 256
      memory    = 512
      essential = true

      # Headless mode targeting the Internal ALB of the app
      command = [
        "locust",
        "-f", "locustfile.py",
        "--headless",
        "-u", "5",
        "-r", "1",
        "--host", "http://${aws_lb.internal.dns_name}:8000"
      ]

      environment = [
        { name = "AWS_REGION", value = var.aws_region }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.locust_logs.name
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
resource "aws_ecs_service" "locust" {
  name            = "${var.project_name}-locust-svc-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.locust.arn
  desired_count   = 1 # Always run one instance for background traffic
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # Locust doesn't need a load balancer listener as it's purely a generator
}
