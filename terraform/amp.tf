resource "aws_prometheus_workspace" "main" {
  alias = "${var.project_name}-amp-${var.environment}"

  tags = {
    Name = "${var.project_name}-amp-${var.environment}"
  }
}
