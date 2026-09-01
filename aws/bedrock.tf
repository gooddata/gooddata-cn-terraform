###
# AWS Bedrock as the LLM provider for GoodData.CN GenAI features (optional)
###

module "bedrock" {
  count  = var.enable_bedrock_llm ? 1 : 0
  source = "../modules/bedrock"

  providers = {
    aws      = aws
    external = external
  }

  deployment_name  = var.deployment_name
  aws_profile_name = var.aws_profile_name
  aws_region       = var.aws_region
  iam_user_name    = var.bedrock_iam_user_name
  default_model_id = var.bedrock_default_model_id
  models           = var.bedrock_models
}
