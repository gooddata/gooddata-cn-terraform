###
# Provision VPC
###

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
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
  version = "~> 5.0"

  name = var.deployment_name
  cidr = local.vpc_cidr
  azs  = local.azs

  # Create one public/private subnet in each AZ
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${var.deployment_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.deployment_name}" = "shared"
  }
}
