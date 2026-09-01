###
# IAM user with static credentials for the GoodData.CN Bedrock LLM provider
#
# GoodData.CN's AWS_BEDROCK llmProvider config only accepts an explicit
# access-key-id and secret-access-key, so IRSA (STS) cannot be used here.
###

locals {
  # Newer Bedrock models reject direct on-demand invocation and must be called
  # through a geo-prefixed inference profile ID (eu., us., apac., global.).
  inference_profile_prefix = lookup(
    {
      eu = "eu."
      us = "us."
      ap = "apac."
    },
    split("-", var.aws_region)[0],
    "global."
  )

  default_model_id = var.default_model_id != "" ? var.default_model_id : "${local.inference_profile_prefix}anthropic.claude-sonnet-4-5-20250929-v1:0"

  model_id_segments    = split(".", local.default_model_id)
  default_model_vendor = contains(["eu", "us", "apac", "global", "jp", "au", "ca", "us-gov"], local.model_id_segments[0]) && length(local.model_id_segments) > 1 ? local.model_id_segments[1] : local.model_id_segments[0]
  default_model_family = lookup(
    {
      anthropic = "ANTHROPIC"
      amazon    = "AMAZON"
      meta      = "META"
      mistral   = "MISTRAL"
      openai    = "OPENAI"
      google    = "GOOGLE"
      cohere    = "COHERE"
    },
    local.default_model_vendor,
    "UNKNOWN"
  )

  models = length(var.models) > 0 ? var.models : [{ family = local.default_model_family, id = local.default_model_id }]
}

resource "aws_iam_user" "bedrock" {
  name = "${var.deployment_name}-bedrock"
}

resource "aws_iam_policy" "bedrock_invoke" {
  name        = "${var.deployment_name}-BedrockInvoke"
  description = "Allow the GoodData.CN GenAI services to invoke and enumerate Bedrock models."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowBedrockInvoke",
        Effect = "Allow",
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel",
          "bedrock:ListInferenceProfiles",
          "bedrock:GetInferenceProfile"
        ],
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "bedrock" {
  user       = aws_iam_user.bedrock.name
  policy_arn = aws_iam_policy.bedrock_invoke.arn
}

resource "aws_iam_access_key" "bedrock" {
  user = aws_iam_user.bedrock.name
}

output "access_key_id" {
  description = "Access key ID for the Bedrock IAM user."
  value       = aws_iam_access_key.bedrock.id
}

output "default_model_id" {
  description = "Resolved default Bedrock model or inference profile ID."
  value       = local.default_model_id
}

output "iam_user_arn" {
  description = "ARN of the Bedrock IAM user."
  value       = aws_iam_user.bedrock.arn
}

output "models" {
  description = "Resolved list of models advertised to GoodData.CN."
  value       = local.models
}

output "secret_access_key" {
  description = "Secret access key for the Bedrock IAM user."
  value       = aws_iam_access_key.bedrock.secret
  sensitive   = true
}
