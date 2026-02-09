output "postgres_namespace" {
  description = "Namespace used for the in-cluster PostgreSQL (CloudNativePG) resources."
  value       = kubernetes_namespace.postgres.metadata[0].name
}

output "minio_namespace" {
  description = "Namespace used for MinIO resources."
  value       = kubernetes_namespace.minio.metadata[0].name
}

output "minio_s3_endpoint" {
  description = "In-cluster MinIO S3 endpoint override URL (with scheme)."
  value = format(
    "http://%s.%s.svc.cluster.local:%s",
    var.minio_release_name,
    kubernetes_namespace.minio.metadata[0].name,
    "9000",
  )
}

output "minio_region" {
  description = "Region string to use for S3 clients when targeting MinIO."
  value       = var.minio_region
}

output "minio_bucket_exports" {
  description = "MinIO bucket for exports."
  value       = var.minio_bucket_exports
}

output "minio_bucket_datasource_fs" {
  description = "MinIO bucket for datasource filesystem (CSV uploads)."
  value       = var.minio_bucket_datasource_fs
}

output "minio_bucket_quiver_cache" {
  description = "MinIO bucket for Quiver durable cache."
  value       = var.minio_bucket_quiver_cache
}

output "minio_gdcn_access_key" {
  description = "Access key for the dedicated GoodData.CN MinIO user."
  value       = "gdcn"
}

output "minio_gdcn_secret_key" {
  description = "Secret key for the dedicated GoodData.CN MinIO user."
  value       = kubernetes_secret.minio_gdcn_user.data["secretKey"]
  sensitive   = true
}

