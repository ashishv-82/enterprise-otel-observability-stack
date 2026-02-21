resource "aws_ssm_parameter" "amp_url" {
  name        = "/${var.project_name}/${var.environment}/amp_remote_write_url"
  description = "Remote Write URL for Amazon Managed Prometheus"
  type        = "String"
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}

resource "aws_ssm_parameter" "loki_s3_bucket" {
  name        = "/${var.project_name}/${var.environment}/loki_s3_bucket"
  description = "Name of the S3 bucket used by Loki for log storage"
  type        = "String"
  value       = aws_s3_bucket.loki.id
}
