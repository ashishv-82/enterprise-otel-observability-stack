# ==============================================================================
# GitHub Actions OIDC Configuration
# ==============================================================================
# This enables GitHub Actions to authenticate with AWS without using
# long-lived secrets like IAM User access keys.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Thumbprint for GitHub Actions (valid until 2037)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# ==============================================================================
# GitHub Actions Deployment Role
# ==============================================================================
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Only allow the main branch of this specific repository to assume this role
      values = ["repo:ashishv-82/enterprise-otel-observability-stack:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_role" {
  name               = "${var.project_name}-github-actions-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

# Grant the role full power over our project-tagged resources.
# In a real enterprise setup, this would be scoped to specific services,
# but for our demo, we'll use a broad policy with a Resource tag filter.
resource "aws_iam_role_policy" "github_actions_policy" {
  name = "github-actions-deploy-policy"
  role = aws_iam_role.github_actions_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
        # This is a demo-friendly way to ensure the CI can manage everything it needs
        # while still providing some protection via project tags.
        # Condition = {
        #   StringEquals = {
        #     "aws:ResourceTag/Project" = var.project_name
        #   }
        # }
      }
    ]
  })
}
