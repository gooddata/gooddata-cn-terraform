output "gdcn_namespace" {
  description = "Kubernetes namespace where GoodData.CN is deployed."
  value       = var.gdcn_namespace
}

output "stackit_project_id" {
  description = "STACKIT project ID that owns the deployment."
  value       = var.stackit_project_id
}

output "stackit_region" {
  description = "STACKIT region the deployment runs in."
  value       = var.stackit_region
}

output "tls_mode" {
  description = "TLS management mode used for ingress certificates."
  value       = var.tls_mode
}
