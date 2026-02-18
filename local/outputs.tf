output "auth_hostname" {
  description = "The hostname for the default Dex authentication ingress."
  value       = module.k8s_common.auth_hostname
}

output "hosts_file_entries" {
  description = "Hostnames to map to 127.0.0.1 for local access (e.g., /etc/hosts)."
  value = [
    for hostname in distinct(compact(concat([module.k8s_common.auth_hostname], module.k8s_common.org_domains))) : {
      hostname = hostname
      ip       = "127.0.0.1"
    }
  ]
}

output "k3d_cluster_name" {
  description = "k3d cluster name managed by this Terraform root module."
  value       = var.k3d_cluster_name
}

output "kubeconfig_context" {
  description = "Kubeconfig context name used for provisioning."
  value       = local.kubeconfig_context
}

output "kubeconfig_path" {
  description = "Path to kubeconfig file used for provisioning (expanded)."
  value       = local.kubeconfig_path
}

output "org_domains" {
  description = "All GoodData.CN organization hostnames derived from gdcn_orgs."
  value       = module.k8s_common.org_domains
}

output "org_ids" {
  description = "List of organization IDs/DNS labels allowed by this deployment."
  value       = module.k8s_common.org_ids
}

output "tls_mode" {
  description = "TLS mode used by this deployment."
  value       = var.tls_mode
}
