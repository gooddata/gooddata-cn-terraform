###
# Provision VPC
###

locals {
  create_vpc         = var.existing_vpc_id == ""
  vpc_id             = local.create_vpc ? module.vpc[0].vpc_id : var.existing_vpc_id
  private_subnet_ids = local.create_vpc ? module.vpc[0].private_subnets : var.existing_private_subnet_ids
}

resource "terraform_data" "validate_existing_vpc" {
  count = local.create_vpc ? 0 : 1

  lifecycle {
    precondition {
      condition     = length(var.existing_private_subnet_ids) >= 2
      error_message = "existing_private_subnet_ids must contain at least 2 entries when existing_vpc_id is set."
    }
    precondition {
      condition     = length(var.existing_public_subnet_ids) >= 2
      error_message = "existing_public_subnet_ids must contain at least 2 entries when existing_vpc_id is set."
    }
  }
}

data "aws_availability_zones" "available" {
  count = local.create_vpc ? 1 : 0
  state = "available"
}

locals {
  azs      = local.create_vpc ? slice(data.aws_availability_zones.available[0].names, 0, 2) : []
  vpc_cidr = "10.0.0.0/16"

  public_subnet_cidrs = [
    for idx in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, idx)
  ]

  private_subnet_cidrs = [
    for idx in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 8, idx + length(local.azs))
  ]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  count = local.create_vpc ? 1 : 0

  name = var.deployment_name
  cidr = local.vpc_cidr
  azs  = local.azs

  # Create one public/private subnet in each AZ
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs

  enable_nat_gateway = true
  # Using single NAT gateway for cost optimization
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags

  public_subnet_tags = {
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${var.deployment_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.deployment_name}" = "shared"
  }
}
