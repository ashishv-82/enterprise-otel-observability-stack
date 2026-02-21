# ==============================================================================
# Outputs — useful values to reference after terraform apply
# ==============================================================================

output "grafana_url" {
  description = "Public URL to access the Grafana dashboard"
  value       = "http://${aws_lb.public.dns_name}"
}

output "app_internal_url" {
  description = "Internal ALB URL for the FastAPI app (within VPC only)"
  value       = "http://${aws_lb.internal.dns_name}:8000"
}

output "loki_internal_url" {
  description = "Internal ALB URL for Loki (within VPC only)"
  value       = "http://${aws_lb.internal.dns_name}:3100"
}

output "ecr_app_repository_url" {
  description = "ECR repository URL for the FastAPI app image"
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_locust_repository_url" {
  description = "ECR repository URL for the Locust image"
  value       = aws_ecr_repository.locust.repository_url
}

output "github_actions_role_arn" {
  description = "IAM Role ARN to paste into GitHub Secrets as AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions_role.arn
}

output "amp_remote_write_url" {
  description = "AMP Remote Write URL (also stored in SSM)"
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}
