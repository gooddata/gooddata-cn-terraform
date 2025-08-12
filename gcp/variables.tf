variable "gcp_project_id" {
  description = "GCP project ID to deploy resources into."
  type        = string
}

variable "gcp_region" {
  description = "GCP region to deploy resources to."
  type        = string
  default     = "us-central1"
}

variable "deployment_name" {
  description = "Name prefix for all GCP resources."
  type        = string
  default     = "gooddata-cn"
}

// Docker Hub credentials retained for parity but not used by current AR remote config
// Keep for future: may wire into AR if provider adds credential support

variable "ar_cache_images" {
  description = "If true, Artifact Registry remote repositories will be created and all services configured to use them. If false, images are pulled from their original registries."
  type        = bool
  default     = false
}


variable "gke_machine_type" {
  description = "Machine type for GKE node pool (close to AWS m6i.large: 2 vCPU, 8GB)."
  type        = string
  default     = "e2-standard-2"
}

variable "gke_max_nodes" {
  description = "Maximum number of nodes in the default node pool."
  type        = number
  default     = 5
}

variable "gdcn_license_key" {
  description = "GoodData.CN license key (provided by your GoodData contact)"
  type        = string
  sensitive   = true
}

variable "letsencrypt_email" {
  description = "Email address used for Let's Encrypt ACME registration"
  type        = string
}

variable "wildcard_dns_provider" {
  description = "Wildcard DNS service used to give a dynamic hostname for hosting GoodData.CN. [default: sslip.io]"
  type        = string
  default     = "sslip.io"
}

variable "s3_endpoint_override" {
  description = "Optional S3-compatible endpoint override for object storage (e.g., https://storage.googleapis.com on GCP)."
  type        = string
  default     = ""
}

variable "helm_cert_manager_version" {
  description = "Version of the cert-manager Helm chart to deploy. https://artifacthub.io/packages/helm/cert-manager/cert-manager"
  type        = string
  default     = "v1.18.2"
}

variable "helm_metrics_server_version" {
  description = "Version of the metrics-server Helm chart to deploy. https://artifacthub.io/packages/helm/metrics-server/metrics-server"
  type        = string
  default     = "3.13.0"
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy. https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx"
  type        = string
  default     = "4.12.3"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy. https://artifacthub.io/packages/helm/gooddata-cn/gooddata-cn"
  type        = string
}

variable "helm_pulsar_version" {
  description = "Version of the pulsar Helm chart to deploy. https://artifacthub.io/packages/helm/apache/pulsar"
  type        = string
  default     = "3.9.0"
}


