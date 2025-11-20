###
# Simple Email Service configuration for GoodData.CN SMTP
###

locals {
  ses_smtp_host = "email-smtp.${var.aws_region}.amazonaws.com"
}

resource "aws_ses_email_identity" "gdcn" {
  email = var.ses_sender_email
}

resource "aws_iam_user" "ses_smtp" {
  name = "${var.deployment_name}-ses-smtp"

  tags = merge(
    {
      Name = "${var.deployment_name}-ses-smtp"
    },
    var.aws_additional_tags
  )
}

resource "aws_iam_user_policy" "ses_smtp" {
  name = "${var.deployment_name}-ses-smtp"
  user = aws_iam_user.ses_smtp.name

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
  user = aws_iam_user.ses_smtp.name
}

output "ses_smtp_host" {
  description = "SMTP host endpoint for SES"
  value       = local.ses_smtp_host
}

output "ses_smtp_username" {
  description = "SMTP username (AWS access key ID)"
  value       = aws_iam_access_key.ses_smtp.id
}

output "ses_smtp_password" {
  description = "SMTP password derived from the IAM access key secret"
  value       = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
  sensitive   = true
}

