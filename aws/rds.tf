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

# Local values for convenience
locals {
  db_username = "postgres"
  db_password = random_password.db_password.result
}

# RDS PostgreSQL via module
module "rds_postgresql" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

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
  password                    = local.db_password
  manage_master_user_password = false

  # Networking
  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [module.eks.node_security_group_id]
  create_db_subnet_group = true

  # Connectivity & lifecycle
  publicly_accessible = false
  storage_encrypted   = true
  skip_final_snapshot = true
  deletion_protection = false

  depends_on = [
    module.vpc
  ]
}
