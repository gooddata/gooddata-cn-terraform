###
# Provision STACKIT Object Storage
#
# Static S3 keys, project-scoped: both key pairs reach every bucket; the two groups
# only allow independent rotation. Destroy needs the buckets emptied first (see README).
###

# Bucket names are unique across the whole project, so they carry a suffix.
resource "random_id" "bucket_suffix" {
  byte_length = 3
}

locals {
  bucket_prefix = "${substr(join("", regexall("[0-9a-z]", lower(var.deployment_name))), 0, 18)}${random_id.bucket_suffix.hex}"

  # exports is created on its own first; see stackit_objectstorage_bucket.exports.
  buckets = concat(
    ["quiver-cache", "quiver-datasource-fs", "loki", "tempo"],
    var.geo_basemap_provider != "none" ? ["geo-collections"] : [],
  )

  bucket_names = merge(
    { exports = stackit_objectstorage_bucket.exports.name },
    { for key, bucket in stackit_objectstorage_bucket.buckets : key => bucket.name },
  )
}

# The first bucket enables Object Storage on the project; parallel creates race and
# fail with 409 "Two concurrent calls try to create the same project", so this goes first.
resource "stackit_objectstorage_bucket" "exports" {
  project_id = var.stackit_project_id
  name       = "${local.bucket_prefix}-exports"
}

resource "stackit_objectstorage_bucket" "buckets" {
  for_each = toset(local.buckets)

  project_id = var.stackit_project_id
  name       = "${local.bucket_prefix}-${each.value}"

  depends_on = [stackit_objectstorage_bucket.exports]
}

# One credentials group and key pair per consumer, created after the exports bucket
# so the project-enable call has finished.
resource "stackit_objectstorage_credentials_group" "main" {
  for_each = toset(["gdcn", "observability"])

  project_id = var.stackit_project_id
  name       = "${var.deployment_name}-${each.key}"

  depends_on = [stackit_objectstorage_bucket.exports]
}

# Keys don't expire. Rotate: terraform apply -replace='stackit_objectstorage_credential.main["gdcn"]',
# then restart the consumers.
resource "stackit_objectstorage_credential" "main" {
  for_each = stackit_objectstorage_credentials_group.main

  project_id           = var.stackit_project_id
  credentials_group_id = each.value.credentials_group_id
}

locals {
  # Derived from the provider's bucket URL, not hardcoded. The chart wants the full
  # URL; the Loki/Tempo S3 clients want a bare host.
  s3_endpoint_url  = regex("^https://[^/]+", stackit_objectstorage_bucket.exports.url_path_style)
  s3_endpoint_host = replace(local.s3_endpoint_url, "https://", "")
}
