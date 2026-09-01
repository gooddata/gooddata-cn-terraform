###
# IAM user with static credentials for the GoodData.CN Bedrock LLM provider
#
# GoodData.CN's AWS_BEDROCK llmProvider config only accepts an explicit
# access-key-id and secret-access-key, so IRSA (STS) cannot be used here.
#
# An existing user is reused instead of creating a new one per deployment:
# var.iam_user_name if set (must exist), otherwise an externally provisioned
# user tagged Purpose=gdcn-genai-bedrock. Discovery only runs while this
# deployment has no user of its own, and users created here carry the
# distinct Purpose=gdcn-genai-bedrock-managed tag, so a stack never adopts
# its own user or one that another stack manages (and may destroy).
# Reused users are expected to already carry Bedrock invoke permissions and
# are never destroyed by this stack; only the access key is managed for them.
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

  bedrock_discovery_tag = "gdcn-genai-bedrock"
  created_user_name     = "${var.deployment_name}-bedrock"
}

# Probe for a reusable IAM user. An empty result means "create". Only
# NoSuchEntity counts as not-found; other IAM failures abort the probe so a
# transient error can never flip an established deployment out of its mode.
data "external" "bedrock_user_probe" {
  program = [
    "bash", "-c",
    <<-EOT
      set -euo pipefail

      iam() {
        # IAM is global; pin the signing region so region-less profiles work.
        aws iam "$@" --profile "${var.aws_profile_name}" --region us-east-1
      }

      user_exists() {
        err=$(iam get-user --user-name "$1" 2>&1 >/dev/null) && return 0
        case "$err" in *NoSuchEntity*) return 1 ;; esac
        echo "$err" >&2
        exit 1
      }

      key_count() {
        iam list-access-keys --user-name "$1" \
          --query 'length(AccessKeyMetadata)' --output text
      }

      name=""
      if [ -n "${var.iam_user_name}" ]; then
        if user_exists "${var.iam_user_name}"; then
          name="${var.iam_user_name}"
        fi
      elif ! user_exists "${local.created_user_name}"; then
        # No user of our own yet: adopt an externally provisioned one if any.
        # The tagging API lists IAM (global) resources only in us-east-1.
        arns=$(aws resourcegroupstaggingapi get-resources \
          --resource-type-filters iam:user \
          --tag-filters "Key=Purpose,Values=${local.bedrock_discovery_tag}" \
          --region us-east-1 \
          --profile "${var.aws_profile_name}" \
          --query 'sort(ResourceTagMappingList[].ResourceARN)' \
          --output text 2>/dev/null || true)
        for arn in $arns; do
          candidate="$${arn##*/}"
          [ -n "$candidate" ] && [ "$candidate" != "None" ] || continue
          [ "$candidate" != "${local.created_user_name}" ] || continue
          if [ "$(key_count "$candidate" || echo 2)" -lt 2 ]; then
            name="$candidate"
            break
          fi
        done
      fi

      printf '{"user_name":"%s"}' "$name"
    EOT
  ]
}

locals {
  existing_user_name = data.external.bedrock_user_probe.result.user_name
  reuse_existing     = local.existing_user_name != ""
}

data "aws_iam_user" "existing" {
  count     = local.reuse_existing ? 1 : 0
  user_name = local.existing_user_name
}

resource "aws_iam_user" "bedrock" {
  count = local.reuse_existing ? 0 : 1
  name  = local.created_user_name
  # Deliberately NOT the discovery tag: other stacks must not adopt a user
  # this stack manages and will destroy.
  tags = { Purpose = "${local.bedrock_discovery_tag}-managed" }
}

resource "aws_iam_user_policy" "bedrock_invoke" {
  count = local.reuse_existing ? 0 : 1
  name  = "gdcn-bedrock-invoke"
  user  = aws_iam_user.bedrock[0].name

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

resource "aws_iam_access_key" "bedrock" {
  user = local.reuse_existing ? data.aws_iam_user.existing[0].user_name : aws_iam_user.bedrock[0].name

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.iam_user_name == "" || local.reuse_existing
      error_message = "iam_user_name is set but that IAM user was not found. Create the user first or leave iam_user_name empty."
    }
    precondition {
      condition     = var.iam_user_name != local.created_user_name
      error_message = "iam_user_name must not be this deployment's own <deployment_name>-bedrock user. To recover a leftover user, delete it or import it into state."
    }
  }
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
  value       = local.reuse_existing ? data.aws_iam_user.existing[0].arn : aws_iam_user.bedrock[0].arn
}

output "iam_user_name" {
  description = "Name of the Bedrock IAM user."
  value       = local.reuse_existing ? data.aws_iam_user.existing[0].user_name : aws_iam_user.bedrock[0].name
}

output "models" {
  description = "Resolved list of models advertised to GoodData.CN."
  value       = local.models
}

output "reused_existing_user" {
  description = "Whether an existing IAM user was reused instead of creating one."
  value       = local.reuse_existing
}

output "secret_access_key" {
  description = "Secret access key for the Bedrock IAM user."
  value       = aws_iam_access_key.bedrock.secret
  sensitive   = true
}
