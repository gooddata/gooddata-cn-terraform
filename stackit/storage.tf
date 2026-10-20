###
# Provision STACKIT Object Storage
#
# Buckets for:
# - quiver-cache:          query acceleration cache
# - quiver-datasource-fs:  data source files (e.g. uploaded CSVs)
# - exports:               exported reports or data
# - loki / tempo:          observability object storage
#
# STACKIT Object Storage authenticates with static S3 access keys, not workload
# identity, so there is no counterpart to the other clouds' IRSA / UAMI wiring.
# Credentials are project-scoped, not per-bucket: both key pairs below can reach
# every bucket. The two groups exist so each consumer's keys can be rotated or
# revoked independently, NOT to isolate GoodData.CN data from observability.
#
# Deleting a bucket that still holds objects fails, so `terraform destroy` needs
# the buckets emptied first (see README).
###

# Bucket names are unique across the whole project, so they carry a suffix.
resource "random_id" "bucket_suffix" {
  byte_length = 3
}

locals {
  bucket_prefix = "${substr(join("", regexall("[0-9a-z]", lower(var.deployment_name))), 0, 18)}${random_id.bucket_suffix.hex}"

  buckets = [
    "quiver-cache",
    "quiver-datasource-fs",
    "exports",
    "loki",
    "tempo",
  ]
}

resource "stackit_objectstorage_bucket" "buckets" {
  for_each = toset(local.buckets)

  project_id = var.stackit_project_id
  name       = "${local.bucket_prefix}-${each.value}"
}

# Both credentials groups follow the buckets so the call that enables object
# storage on the project has finished before more resources pile onto it.
resource "stackit_objectstorage_credentials_group" "gdcn" {
  project_id = var.stackit_project_id
  name       = "${var.deployment_name}-gdcn"

  depends_on = [stackit_objectstorage_bucket.buckets]
}

# No expiration_timestamp: the key does not expire. Rotate by changing
# rotate_when_changed and restarting the consumers.
resource "stackit_objectstorage_credential" "gdcn" {
  project_id           = var.stackit_project_id
  credentials_group_id = stackit_objectstorage_credentials_group.gdcn.credentials_group_id
}

resource "stackit_objectstorage_credentials_group" "observability" {
  project_id = var.stackit_project_id
  name       = "${var.deployment_name}-observability"

  depends_on = [stackit_objectstorage_bucket.buckets]
}

resource "stackit_objectstorage_credential" "observability" {
  project_id           = var.stackit_project_id
  credentials_group_id = stackit_objectstorage_credentials_group.observability.credentials_group_id
}

locals {
  # Derived from the provider's own bucket URL rather than hardcoded, so a change
  # to STACKIT's storage domain doesn't need a code change here. The GoodData.CN
  # chart wants the full URL; the Loki/Tempo S3 clients want a bare host.
  s3_endpoint_url  = regex("^https://[^/]+", stackit_objectstorage_bucket.buckets["exports"].url_path_style)
  s3_endpoint_host = replace(local.s3_endpoint_url, "https://", "")
}
