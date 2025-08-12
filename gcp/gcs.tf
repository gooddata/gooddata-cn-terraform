###
# GCS buckets and S3-compatible HMAC keys
###

resource "random_id" "gcs_suffix" {
  byte_length = 3
}

locals {
  bucket_prefix = format(
    "%s-%s",
    replace(lower(var.deployment_name), "[^0-9a-z-]", "-"),
    random_id.gcs_suffix.hex
  )

  gcs_buckets = {
    quiver_cache  = "-quiver-cache"
    datasource_fs = "-quiver-datasource-fs"
    exports       = "-exports"
  }
}

resource "google_storage_bucket" "buckets" {
  for_each      = local.gcs_buckets
  name          = substr("${local.bucket_prefix}${each.value}", 0, 63)
  location      = var.gcp_region
  force_destroy = true

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = null
  }
}

# Create a service account with HMAC keys for S3-compatible access
resource "google_service_account" "gcs_s3_compat" {
  account_id   = "${var.deployment_name}-gcs-s3"
  display_name = "${var.deployment_name} GCS S3-compat access"
}

resource "google_project_iam_member" "gcs_roles" {
  for_each = toset([
    "roles/storage.objectAdmin",
    "roles/storage.legacyBucketReader",
  ])
  project = var.gcp_project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gcs_s3_compat.email}"
}

resource "google_storage_hmac_key" "s3_hmac" {
  service_account_email = google_service_account.gcs_s3_compat.email
}

output "gcs_buckets" {
  description = "Map of created GCS bucket names"
  value       = { for k, v in google_storage_bucket.buckets : k => v.name }
}

output "gcs_s3_access_key_id" {
  value     = google_storage_hmac_key.s3_hmac.access_id
  sensitive = true
}

output "gcs_s3_secret_access_key" {
  value     = google_storage_hmac_key.s3_hmac.secret
  sensitive = true
}


