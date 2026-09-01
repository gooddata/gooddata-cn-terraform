variable "aws_profile_name" { type = string }

variable "aws_region" { type = string }

variable "default_model_id" {
  description = "Bedrock model or inference profile ID used as the GoodData.CN default. Empty selects Claude Sonnet 4.5 under the region's inference profile prefix."
  type        = string
  default     = ""
}

variable "deployment_name" { type = string }

variable "iam_user_name" {
  description = "Existing IAM user to reuse for Bedrock access; must exist. Empty auto-discovers an externally provisioned user tagged Purpose=gdcn-genai-bedrock while this deployment has no user of its own, and creates <deployment_name>-bedrock when none is found. Reused users must already carry Bedrock invoke permissions and need a free access key slot."
  type        = string
  default     = ""
}

variable "models" {
  description = "Models advertised to GoodData.CN. Empty defaults to the resolved default_model_id. family is one of OPENAI, ANTHROPIC, META, MISTRAL, AMAZON, GOOGLE, COHERE, UNKNOWN."
  type = list(object({
    family = string
    id     = string
  }))
  default = []
}
