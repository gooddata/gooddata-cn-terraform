###
# Simple Email Service configuration for GoodData.CN SMTP
###

locals {
  ses_enabled   = trimspace(var.ses_sender_email) != ""
  ses_smtp_host = "email-smtp.${var.aws_region}.amazonaws.com"
}

resource "aws_ses_email_identity" "gdcn" {
  count = local.ses_enabled ? 1 : 0
  email = var.ses_sender_email
}

resource "aws_iam_user" "ses_smtp" {
  count = local.ses_enabled ? 1 : 0
  name  = "${var.deployment_name}-ses-smtp"

  tags = merge(
    {
      Name = "${var.deployment_name}-ses-smtp"
    },
    var.aws_additional_tags
  )
}

resource "aws_iam_user_policy" "ses_smtp" {
  count = local.ses_enabled ? 1 : 0
  name  = "${var.deployment_name}-ses-smtp"
  user  = aws_iam_user.ses_smtp[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  count = local.ses_enabled ? 1 : 0
  user  = aws_iam_user.ses_smtp[0].name
}

output "ses_smtp_host" {
  description = "SMTP host endpoint for SES"
  value       = local.ses_enabled ? local.ses_smtp_host : ""
}

output "ses_smtp_username" {
  description = "SMTP username (AWS access key ID)"
  value       = local.ses_enabled ? aws_iam_access_key.ses_smtp[0].id : ""
}

output "ses_smtp_password" {
  description = "SMTP password derived from the IAM access key secret"
  value       = local.ses_enabled ? aws_iam_access_key.ses_smtp[0].ses_smtp_password_v4 : ""
  sensitive   = true
}

