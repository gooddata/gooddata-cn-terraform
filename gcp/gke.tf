###
# GKE Standard cluster (private nodes, public control plane)
###

resource "google_compute_address" "ingress" {
  name   = "${var.deployment_name}-ingress"
  region = var.gcp_region
}

resource "google_container_cluster" "primary" {
  name     = var.deployment_name
  location = var.gcp_region

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.private.id

  release_channel {
    channel = "REGULAR"
  }

  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {}

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_global_access_config {
      enabled = true
    }
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  depends_on = [
    google_compute_subnetwork.private,
  ]
}

resource "google_container_node_pool" "default" {
  name       = "default-pool"
  location   = var.gcp_region
  cluster    = google_container_cluster.primary.name
  node_count = 2

  autoscaling {
    min_node_count = 1
    max_node_count = var.gke_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.gke_machine_type
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    # Workload Identity enabled by default in modern GKE; SA binding will be done per k8s add-ons if needed
    metadata = {
      disable-legacy-endpoints = "true"
    }
    labels = {
      project = var.deployment_name
    }
    tags = [
      "${var.deployment_name}-nodes"
    ]
  }
}

output "gke_cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.primary.name
}


