# ==============================================================================
# Public ALB (For Grafana)
# ==============================================================================
resource "aws_lb" "public" {
  name               = "${var.project_name}-public-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  tags = {
    Name = "${var.project_name}-public-alb-${var.environment}"
  }
}

resource "aws_lb_target_group" "grafana" {
  name        = "${var.project_name}-grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/api/health" # Grafana healthcheck endpoint
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 10
    interval            = 30
  }
}

resource "aws_lb_listener" "grafana_http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# ==============================================================================
# Internal ALB (For App and Loki)
# ==============================================================================
resource "aws_lb" "internal" {
  name               = "${var.project_name}-int-alb-${var.environment}"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_tasks.id]
  subnets            = module.vpc.private_subnets

  tags = {
    Name = "${var.project_name}-internal-alb-${var.environment}"
  }
}

# App Target Group (Port 8000)
resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-app-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 15
  }
}

resource "aws_lb_listener" "app_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 8000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Loki Target Group (Port 3100)
resource "aws_lb_target_group" "loki" {
  name        = "${var.project_name}-loki-tg"
  port        = 3100
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/ready" # Loki healthcheck endpoint
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 15
  }
}

resource "aws_lb_listener" "loki_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 3100
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loki.arn
  }
}
