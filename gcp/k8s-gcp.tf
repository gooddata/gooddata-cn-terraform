###
# Deploy GCP-specific k8s add-ons (ingress + default storage)
###

module "k8s_gcp" {
  source = "../modules/k8s-gcp"

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  deployment_name            = var.deployment_name
  helm_ingress_nginx_version = var.helm_ingress_nginx_version
  registry_k8sio             = local.registry_k8sio
  ingress_static_ip_address  = google_compute_address.ingress.address
}


