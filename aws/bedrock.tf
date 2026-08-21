###
# Optional: Amazon Bedrock access for GoodData.CN AI features
#
# When enable_bedrock_llm = true, provisions a dedicated IAM user with
# invoke-only Bedrock permissions. Register the resulting access key as the
# GoodData.CN LLM provider with ../scripts/create-bedrock-provider.sh after
# the deployment is up.
###

resource "aws_iam_user" "bedrock_llm" {
  count = var.enable_bedrock_llm ? 1 : 0
  name  = "${var.deployment_name}-bedrock-llm"
}

resource "aws_iam_user_policy" "bedrock_llm_invoke" {
  count = var.enable_bedrock_llm ? 1 : 0
  name  = "${var.deployment_name}-bedrock-invoke"
  user  = aws_iam_user.bedrock_llm[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel",
          "bedrock:ListInferenceProfiles",
          "bedrock:GetInferenceProfile",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "bedrock_llm" {
  count = var.enable_bedrock_llm ? 1 : 0
  user  = aws_iam_user.bedrock_llm[0].name
}
