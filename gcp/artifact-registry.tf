###
# Optional Artifact Registry remote repositories to cache upstream images
###

locals {
  registry_dockerio = var.ar_cache_images ? "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.deployment_name}-mirrors/dockerio" : "registry-1.docker.io"
  registry_quayio   = var.ar_cache_images ? "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.deployment_name}-mirrors/quayio" : "quay.io"
  registry_k8sio    = var.ar_cache_images ? "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.deployment_name}-mirrors/k8sio" : "registry.k8s.io"
}

resource "google_artifact_registry_repository" "mirrors" {
  count         = var.ar_cache_images ? 1 : 0
  location      = var.gcp_region
  repository_id = "${var.deployment_name}-mirrors"
  description   = "Remote repositories mirroring public registries"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
}

resource "google_artifact_registry_repository" "dockerio" {
  count         = var.ar_cache_images ? 1 : 0
  location      = var.gcp_region
  repository_id = "dockerio"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  remote_repository_config {}
  docker_config {
    immutable_tags = false
  }
  depends_on = [google_artifact_registry_repository.mirrors]
}

resource "google_artifact_registry_repository" "quayio" {
  count         = var.ar_cache_images ? 1 : 0
  location      = var.gcp_region
  repository_id = "quayio"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  remote_repository_config {}
  docker_config {
    immutable_tags = false
  }
  depends_on = [google_artifact_registry_repository.mirrors]
}

resource "google_artifact_registry_repository" "k8sio" {
  count         = var.ar_cache_images ? 1 : 0
  location      = var.gcp_region
  repository_id = "k8sio"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  remote_repository_config {}
  docker_config {
    immutable_tags = false
  }
  depends_on = [google_artifact_registry_repository.mirrors]
}

output "registry_dockerio" {
  value = local.registry_dockerio
}

output "registry_quayio" {
  value = local.registry_quayio
}

output "registry_k8sio" {
  value = local.registry_k8sio
}


