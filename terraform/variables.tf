variable "project_name" {
  description = "The root name for all resources"
  type        = string
  default     = "enterprise-otel"
}

variable "aws_region" {
  description = "The AWS region to deploy into"
  type        = string
  default     = "ap-southeast-2"
}

variable "environment" {
  description = "The environment name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}
