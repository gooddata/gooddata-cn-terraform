output "seaweedfs_bucket_datasource_fs" {
  description = "SeaweedFS bucket for datasource filesystem (CSV uploads)."
  value       = var.seaweedfs_bucket_datasource_fs
}

output "seaweedfs_bucket_exports" {
  description = "SeaweedFS bucket for exports."
  value       = var.seaweedfs_bucket_exports
}

output "seaweedfs_bucket_loki" {
  description = "SeaweedFS bucket for Loki object storage (chunks/index)."
  value       = var.seaweedfs_bucket_loki
}

output "seaweedfs_bucket_quiver_cache" {
  description = "SeaweedFS bucket for Quiver durable cache."
  value       = var.seaweedfs_bucket_quiver_cache
}

output "seaweedfs_bucket_tempo" {
  description = "SeaweedFS bucket for Tempo trace object storage."
  value       = var.seaweedfs_bucket_tempo
}

output "seaweedfs_gdcn_access_key" {
  description = "Access key for the dedicated GoodData.CN SeaweedFS S3 user."
  value       = local.seaweedfs_s3_access_key
}

output "seaweedfs_gdcn_secret_key" {
  description = "Secret key for the dedicated GoodData.CN SeaweedFS S3 user."
  value       = kubernetes_secret_v1.seaweedfs_s3_credentials.data["secretKey"]
  sensitive   = true
}

output "seaweedfs_loki_access_key" {
  description = "Access key for the Loki SeaweedFS S3 user (scoped to the Loki bucket)."
  value       = "loki"
}

output "seaweedfs_loki_secret_key" {
  description = "Secret key for the Loki SeaweedFS S3 user."
  value       = random_password.seaweedfs_scoped_secret_key["loki"].result
  sensitive   = true
}

output "seaweedfs_namespace" {
  description = "Namespace used for SeaweedFS resources."
  value       = kubernetes_namespace_v1.seaweedfs.metadata[0].name
}

output "seaweedfs_region" {
  description = "Region string to use for S3 clients when targeting SeaweedFS."
  value       = var.s3_region
}

output "seaweedfs_s3_endpoint" {
  description = "In-cluster SeaweedFS S3 endpoint override URL (with scheme)."
  value = format(
    "http://%s-all-in-one.%s.svc.cluster.local:%s",
    var.seaweedfs_release_name,
    kubernetes_namespace_v1.seaweedfs.metadata[0].name,
    "8333",
  )
}

output "seaweedfs_tempo_access_key" {
  description = "Access key for the Tempo SeaweedFS S3 user (scoped to the Tempo bucket)."
  value       = "tempo"
}

output "seaweedfs_tempo_secret_key" {
  description = "Secret key for the Tempo SeaweedFS S3 user."
  value       = random_password.seaweedfs_scoped_secret_key["tempo"].result
  sensitive   = true
}

output "postgres_namespace" {
  description = "Namespace used for the in-cluster PostgreSQL (CloudNativePG) resources."
  value       = kubernetes_namespace_v1.postgres.metadata[0].name
}

