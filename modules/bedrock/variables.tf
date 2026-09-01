variable "aws_region" { type = string }

variable "default_model_id" {
  description = "Bedrock model or inference profile ID used as the GoodData.CN default. Empty selects Claude Sonnet 4.5 under the region's inference profile prefix."
  type        = string
  default     = ""
}

variable "deployment_name" { type = string }

variable "models" {
  description = "Models advertised to GoodData.CN. Empty defaults to the resolved default_model_id. family is one of OPENAI, ANTHROPIC, META, MISTRAL, AMAZON, GOOGLE, COHERE, UNKNOWN."
  type = list(object({
    family = string
    id     = string
  }))
  default = []
}
