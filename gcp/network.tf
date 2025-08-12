###
# GCP VPC and subnets (new VPC)
###

resource "google_compute_network" "vpc" {
  name                    = "${var.deployment_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private" {
  name          = "${var.deployment_name}-private"
  ip_cidr_range = "10.10.0.0/16"
  region        = var.gcp_region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true
}

# Cloud NAT for egress from private nodes without public IPs
resource "google_compute_router" "router" {
  name    = "${var.deployment_name}-router"
  region  = var.gcp_region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.deployment_name}-nat"
  region                             = var.gcp_region
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}


