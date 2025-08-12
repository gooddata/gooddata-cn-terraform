###
# Enable required Google APIs
###

data "google_project" "current" {}

locals {
  required_services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each = toset(local.required_services)
  project  = data.google_project.current.project_id
  service  = each.key

  disable_on_destroy = false
}


