output "gdcn_namespace" {
  description = "Kubernetes namespace where GoodData.CN is deployed."
  value       = var.gdcn_namespace
}

# The SKE kubeconfig is short-lived, so configure-kubectl.sh re-reads this each
# time rather than writing a long-lived context.
output "kubeconfig" {
  description = "Admin kubeconfig for the SKE cluster. Short-lived; re-run scripts/configure-kubectl.sh once it expires."
  value       = stackit_ske_kubeconfig.main.kube_config
  sensitive   = true
}

output "kubeconfig_expires_at" {
  description = "Timestamp when the kubeconfig above expires."
  value       = stackit_ske_kubeconfig.main.expires_at
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
