# ==============================================================================
# ECS Task Execution Role
# ==============================================================================
# This role is assumed by the ECS agent to pull container images from ECR,
# fetch secrets from SSM Parameter Store, and send logs to CloudWatch.
data "aws_iam_policy_document" "ecs_task_execution_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${var.project_name}-ecs-exec-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json
}

# Attach the AWS-managed execution policy (handles ECR and CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Add custom inline policy to allow reading our specific SSM Parameters
data "aws_iam_policy_document" "ecs_task_execution_ssm" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameters",
      "ssm:GetParameter"
    ]
    # Scoped to any parameter starting with our project name to enforce least privilege
    resources = ["arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/*"]
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_ssm_policy" {
  name   = "ssm-permissions"
  role   = aws_iam_role.ecs_task_execution_role.id
  policy = data.aws_iam_policy_document.ecs_task_execution_ssm.json
}

# ==============================================================================
# ECS Task Role
# ==============================================================================
# This role is assumed by the actual containers running in the task.
# The ADOT container requires this role to authenticate with AWS APIs.
resource "aws_iam_role" "ecs_task_role" {
  name               = "${var.project_name}-ecs-task-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json
}

# 1. Allow ADOT to write traces to AWS X-Ray
resource "aws_iam_role_policy_attachment" "xray_write" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

# 1a. Allow Grafana to read traces from AWS X-Ray
resource "aws_iam_role_policy_attachment" "xray_read" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayReadOnlyAccess"
}

# 2. Allow ADOT to write metrics to Amazon Managed Prometheus (AMP)
resource "aws_iam_role_policy_attachment" "amp_write" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
}

# 3. Allow Grafana to query metrics from Amazon Managed Prometheus (AMP)
resource "aws_iam_role_policy_attachment" "amp_query" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

# 3. Allow Loki to read/write log chunks to Amazon S3
data "aws_iam_policy_document" "s3_loki_access" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject"
    ]
    # Using a wildcard for now until the bucket is created in Step 10
    resources = ["arn:aws:s3:::*"]
  }
}

resource "aws_iam_role_policy" "loki_s3_policy" {
  name   = "loki-s3-permissions"
  role   = aws_iam_role.ecs_task_role.id
  policy = data.aws_iam_policy_document.s3_loki_access.json
}
