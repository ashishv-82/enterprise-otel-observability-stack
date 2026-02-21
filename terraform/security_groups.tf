# Security Group for the Application Load Balancer
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg-${var.environment}"
  description = "Security group for the public Application Load Balancer"
  vpc_id      = module.vpc.vpc_id

  # Inbound HTTP traffic to access Grafana (port 80 -> 3000)
  ingress {
    description = "Allow HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg-${var.environment}"
  }
}

# Security Group for the internal ECS Tasks (App, Loki, Grafana)
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-sg-${var.environment}"
  description = "Security group for internal ECS Fargate tasks"
  vpc_id      = module.vpc.vpc_id

  # Allow containers to talk to each other completely inside the VPC
  # E.g. App talking to ADOT, ADOT talking to Loki, Grafana talking to Loki/Prometheus
  ingress {
    description = "Allow all inter-VPC traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  # Allow all outbound traffic from the containers to the internet (via NAT)
  # This is needed for ADOT to reach the public AWS AMP and X-Ray API endpoints,
  # and for ECS to pull images from ECR.
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-tasks-sg-${var.environment}"
  }
}
