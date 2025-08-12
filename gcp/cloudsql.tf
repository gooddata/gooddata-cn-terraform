###
# Cloud SQL for PostgreSQL (private IP)
###

resource "random_password" "db_password" {
  length  = 32
  special = false
}

locals {
  db_username = "postgres"
  db_password = random_password.db_password.result
}

# Serverless VPC Access for private IP connectivity to Cloud SQL (via PSC)
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.self_link
  service                 = "services/servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}

resource "google_compute_global_address" "private_service_range" {
  name          = "${var.deployment_name}-private-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_sql_database_instance" "postgres" {
  name             = var.deployment_name
  region           = var.gcp_region
  database_version = "POSTGRES_16"

  settings {
    tier              = "db-custom-2-8192" # 2 vCPU, 8GB ~ db.t4g.medium class intent
    availability_type = "ZONAL"
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.self_link
    }
    backup_configuration {
      enabled = false
    }
    disk_autoresize = true
    disk_size       = 20
    disk_type       = "PD_SSD"
  }

  deletion_protection = false

  depends_on = [
    google_service_networking_connection.private_vpc_connection
  ]
}

resource "google_sql_user" "postgres" {
  instance = google_sql_database_instance.postgres.name
  name     = local.db_username
  password = local.db_password
}

output "db_instance_address" {
  description = "Private IP address/hostname of Cloud SQL instance"
  value       = google_sql_database_instance.postgres.private_ip_address
}


