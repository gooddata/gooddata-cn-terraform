###
# Provision RDS PostgreSQL for GoodData.CN metadata
###

# Fetch the default PostgreSQL engine version
data "aws_rds_engine_version" "default" {
  engine       = "postgres"
  default_only = true
}

# Generate a strong password for the database
resource "random_password" "db_password" {
  length  = 32
  special = false
}

locals {
  db_username = "postgres"
  db_password = random_password.db_password.result
}

# Security group for RDS PostgreSQL
resource "aws_security_group" "rds" {
  name        = "${var.deployment_name}-rds"
  description = "Security group for RDS PostgreSQL database"
  vpc_id      = module.vpc.vpc_id

  tags = local.common_tags
}

# Allow inbound PostgreSQL traffic from EKS node security group
resource "aws_security_group_rule" "rds_postgres_ingress_from_nodes" {
  type      = "ingress"
  from_port = 5432
  to_port   = 5432
  protocol  = "tcp"
  # Managed node groups attach the cluster primary security group (created by EKS)
  source_security_group_id = module.eks.cluster_primary_security_group_id
  security_group_id        = aws_security_group.rds.id
  description              = "Allow PostgreSQL access from the EKS cluster primary security group"
}

module "rds_postgresql" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.0"

  # Identifier & engine
  identifier        = var.deployment_name
  engine            = "postgres"
  engine_version    = data.aws_rds_engine_version.default.version
  family            = "postgres${split(".", data.aws_rds_engine_version.default.version)[0]}"
  instance_class    = var.rds_instance_class
  allocated_storage = 20
  apply_immediately = true

  # Database name & credentials
  username                    = local.db_username
  password_wo                 = local.db_password
  password_wo_version         = 1
  manage_master_user_password = false

  # Networking
  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds.id]
  create_db_subnet_group = true

  # Connectivity & lifecycle
  publicly_accessible = false
  storage_encrypted   = true
  skip_final_snapshot = var.rds_skip_final_snapshot
  deletion_protection = var.rds_deletion_protection

  tags = local.common_tags
}
