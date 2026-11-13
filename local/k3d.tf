###
# Create / manage local k3d cluster
#
# Note: Kubernetes/Helm providers will still try to connect during plan/refresh.
# If you are creating the cluster for the first time, run:
#   terraform apply -target=null_resource.k3d_cluster -var-file=settings.tfvars
# and then run a full apply.
###

locals {
  k3d_config_content = templatefile("${path.module}/k3d-config.yaml", {
    k3d_cluster_name       = var.k3d_cluster_name
    kubeapi_host           = var.k3d_kubeapi_host
    k3d_agents             = var.k3d_agents
    dockerhub_username     = var.dockerhub_username
    dockerhub_access_token = var.dockerhub_access_token
  })
  k3d_config_sha1 = sha1(local.k3d_config_content)
}

resource "local_file" "k3d_config" {
  filename        = "${path.module}/k3d-config.generated.yaml"
  content         = local.k3d_config_content
  file_permission = "0600"
}

resource "null_resource" "k3d_cluster" {
  triggers = {
    cluster_name    = var.k3d_cluster_name
    k3d_config_sha1 = local.k3d_config_sha1
    kubeconfig_path = local.kubeconfig_path
    kubeconfig_ctx  = local.kubeconfig_context
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      if ! command -v k3d >/dev/null 2>&1; then
        echo "k3d is required. Install it from https://k3d.io/ and retry." >&2
        exit 1
      fi
      if ! command -v docker >/dev/null 2>&1; then
        echo "docker CLI is required for k3d. Install Docker and retry." >&2
        exit 1
      fi

      if k3d cluster list | grep -q "^${var.k3d_cluster_name}[[:space:]]"; then
        echo ">> k3d cluster '${var.k3d_cluster_name}' already exists."
      else
        echo ">> Creating k3d cluster '${var.k3d_cluster_name}'..."
        k3d cluster create -c "${path.module}/k3d-config.generated.yaml"
      fi

      echo ">> Writing kubeconfig to '${local.kubeconfig_path}'..."
      mkdir -p "$(dirname "${local.kubeconfig_path}")"
      k3d kubeconfig merge "${var.k3d_cluster_name}" \
        --output "${local.kubeconfig_path}" \
        --kubeconfig-switch-context=false >/dev/null

      if command -v kubectl >/dev/null 2>&1; then
        echo ">> Using kubectl context '${local.kubeconfig_context}'..."
        KUBECONFIG="${local.kubeconfig_path}" kubectl config use-context "${local.kubeconfig_context}" >/dev/null 2>&1 || true
      fi
    EOT

  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if command -v k3d >/dev/null 2>&1; then
        k3d cluster delete "${self.triggers.cluster_name}" >/dev/null 2>&1 || true
      fi
    EOT
  }

  depends_on = [
    local_file.k3d_config,
  ]
}

# Memory limit of the server nodes through docker update (the k3d serversMemory option bind-mounts a
# file from ~/.config/k3d, which Docker Desktop refuses when Terraform runs in a dev container).
# Separate from null_resource.k3d_cluster: changing k3d_servers_memory updates the running containers
# and never replaces (and deletes) the cluster. It runs again when the cluster is recreated.
resource "null_resource" "k3d_servers_memory" {
  triggers = {
    cluster_id     = null_resource.k3d_cluster.id
    cluster_name   = var.k3d_cluster_name
    servers_memory = var.k3d_servers_memory
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [ -n "${var.k3d_servers_memory}" ]; then
        for c in $(docker ps -q --filter "label=k3d.cluster=${var.k3d_cluster_name}" --filter "label=k3d.role=server"); do
          docker update --memory "${var.k3d_servers_memory}" --memory-swap "${var.k3d_servers_memory}" "$c" >/dev/null
          echo ">> Memory limit ${var.k3d_servers_memory} on server node $c"
        done
      fi
    EOT
  }
}
