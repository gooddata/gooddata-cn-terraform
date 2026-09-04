###
# Deploy self-hosted Langfuse for LLM observability and hand its API keypair to
# the GoodData.CN gen-ai services.
###

locals {
  langfuse_namespace = "langfuse"

  # Literals so clickhouse.tf and valkey.tf can reference them while the feature
  # flag is off.
  langfuse_secret_name             = "langfuse-server-secrets"
  langfuse_keypair_secret_name     = "langfuse-keypair"
  langfuse_clickhouse_password_key = "clickhouse_password"
  langfuse_valkey_password_key     = "valkey_password"

  # Langfuse owns this database; the chart's Prisma migration creates it on first boot.
  langfuse_postgres_database = "langfuse"

  # Each service reads its own langfuse block; one alone enables nothing. These
  # are the only sections the chart wires langfuse into (agenticWorkflows: secret only).
  langfuse_gdcn_sections = [
    "agenticWorkflows",
    "agenticWorkflowsPilot",
    "genAi",
    "genAiMetadataSync",
  ]

  # Chart release name "langfuse" resolves the web Service to "langfuse-web".
  langfuse_web_service = "langfuse-web"

  # Pinned rather than left to the chart's fullname, because the AWS IRSA trust
  # policy names this service account.
  langfuse_service_account_name = "langfuse"

  # Signup is disabled, so this account is the only way into the UI.
  langfuse_admin_email = trimspace(var.langfuse_admin_email)

  # Key names are fixed by the GoodData.CN chart and shared with the gen-ai
  # services; join() over the splat stays valid while the feature flag is off.
  langfuse_keypair_data = {
    langfuse_host       = "http://${local.langfuse_web_service}.${local.langfuse_namespace}.svc.cluster.local:3000"
    langfuse_public_key = "pk-lf-${lower(join("", random_uuid.langfuse_public_key[*].result))}"
    langfuse_secret_key = "sk-lf-${lower(join("", random_uuid.langfuse_secret_key[*].result))}"
  }

  # Declassified so the sensitive mark does not redact the whole values file in
  # every plan.
  langfuse_s3_static_credentials = nonsensitive(trimspace(var.langfuse_s3_access_key_id) != "")

  # ALB health checks default to GET / expecting 200, but langfuse-web redirects
  # / to the sign-in page, so point them at its health endpoint instead.
  langfuse_ingress_annotations = merge(
    local.use_ingress_nginx ? {
      "nginx.ingress.kubernetes.io/proxy-body-size" = "50m"
    } : {},
    local.cert_manager_issuer_annotation,
    var.ingress_annotations_override,
    var.ingress_controller == "alb" ? {
      "alb.ingress.kubernetes.io/healthcheck-path" = "/api/public/health"
    } : {}
  )
}

resource "kubernetes_namespace_v1" "langfuse" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name   = local.langfuse_namespace
    labels = local.istio_injection_labels
  }
}

resource "kubectl_manifest" "peerauth_langfuse_strict" {
  count = var.enable_llm_observability && local.use_istio_gateway ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata   = { name = "default", namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name }
    spec       = { mtls = { mode = "STRICT" } }
  })

  depends_on = [
    helm_release.istiod,
  ]
}

# Disabling regenerates these while the langfuse database survives, and headless
# init only seeds a fresh one, so drop that database before re-enabling.
resource "random_password" "langfuse_init_user" {
  count = var.enable_llm_observability ? 1 : 0

  length           = 24
  special          = true
  override_special = "_%@-"
}

# ClickHouse and Valkey passwords travel inside connection strings, so they stay
# alphanumeric.
resource "random_password" "langfuse_clickhouse" {
  count = var.enable_llm_observability ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "langfuse_valkey" {
  count = var.enable_llm_observability ? 1 : 0

  length  = 32
  special = false
}

resource "random_bytes" "langfuse_nextauth_secret" {
  count = var.enable_llm_observability ? 1 : 0

  length = 32
}

resource "random_bytes" "langfuse_salt" {
  count = var.enable_llm_observability ? 1 : 0

  length = 32
}

# ENCRYPTION_KEY must be exactly 64 hex characters (256 bits).
resource "random_bytes" "langfuse_encryption_key" {
  count = var.enable_llm_observability ? 1 : 0

  length = 32
}

resource "random_uuid" "langfuse_public_key" {
  count = var.enable_llm_observability ? 1 : 0
}

resource "random_uuid" "langfuse_secret_key" {
  count = var.enable_llm_observability ? 1 : 0
}

resource "kubernetes_secret_v1" "langfuse_server_secrets" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = local.langfuse_secret_name
    namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
  }

  data = {
    nextauth_secret                          = random_bytes.langfuse_nextauth_secret[0].base64
    salt                                     = random_bytes.langfuse_salt[0].base64
    encryption_key                           = random_bytes.langfuse_encryption_key[0].hex
    init_user_password                       = random_password.langfuse_init_user[0].result
    postgres_password                        = var.db_password
    (local.langfuse_clickhouse_password_key) = random_password.langfuse_clickhouse[0].result
    (local.langfuse_valkey_password_key)     = random_password.langfuse_valkey[0].result
    s3_access_key_id                         = var.langfuse_s3_access_key_id
    s3_secret_access_key                     = var.langfuse_s3_secret_access_key
  }

  lifecycle {
    # Rotating generated material would orphan the encrypted rows and the
    # passwords baked into ClickHouse/Valkey; module inputs track their source.
    ignore_changes = [
      data["nextauth_secret"],
      data["salt"],
      data["encryption_key"],
      data["init_user_password"],
      data["clickhouse_password"],
      data["valkey_password"],
    ]
  }
}

resource "kubernetes_secret_v1" "langfuse_keypair" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = local.langfuse_keypair_secret_name
    namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
  }

  data = local.langfuse_keypair_data

  lifecycle {
    ignore_changes = [data]
  }
}

# Same keypair inside the GoodData.CN namespace, where the gen-ai pods mount it.
resource "kubernetes_secret_v1" "langfuse_gdcn_keypair" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = local.langfuse_keypair_secret_name
    namespace = var.gdcn_namespace
  }

  data = local.langfuse_keypair_data

  lifecycle {
    ignore_changes = [data]
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}

resource "helm_release" "langfuse" {
  count = var.enable_llm_observability ? 1 : 0

  name       = "langfuse"
  repository = "https://langfuse.github.io/langfuse-k8s"
  chart      = "langfuse"
  version    = var.helm_langfuse_version
  namespace  = kubernetes_namespace_v1.langfuse[0].metadata[0].name

  values = [
    templatefile("${path.module}/templates/langfuse-values.yaml.tftpl", {
      hostname          = var.llm_observability_hostname
      admin_email       = local.langfuse_admin_email
      deployment_name   = var.deployment_name
      registry_dockerio = var.registry_dockerio

      service_account_name        = local.langfuse_service_account_name
      service_account_annotations = var.langfuse_service_account_annotations

      server_secret_name  = local.langfuse_secret_name
      keypair_secret_name = local.langfuse_keypair_secret_name

      web_replicas          = local.langfuse_replicas.web
      web_memory_request    = local.langfuse_mem.web.request
      web_memory_limit      = local.langfuse_mem.web.limit
      worker_replicas       = local.langfuse_replicas.worker
      worker_memory_request = local.langfuse_mem.worker.request
      worker_memory_limit   = local.langfuse_mem.worker.limit

      ingress_enabled         = !local.use_istio_gateway
      ingress_class_name      = local.resolved_ingress_class_name
      ingress_annotations     = local.langfuse_ingress_annotations
      ingress_tls_enabled     = local.use_cert_manager
      ingress_tls_secret_name = "langfuse-tls"

      postgres_host     = var.db_hostname
      postgres_username = var.db_username
      postgres_database = local.langfuse_postgres_database

      clickhouse_host         = local.langfuse_clickhouse_host
      clickhouse_http_port    = local.langfuse_clickhouse_http_port
      clickhouse_native_port  = local.langfuse_clickhouse_native_port
      clickhouse_database     = local.langfuse_clickhouse_database
      clickhouse_username     = local.langfuse_clickhouse_username
      clickhouse_password_key = local.langfuse_clickhouse_password_key

      valkey_host         = local.langfuse_valkey_host
      valkey_port         = local.langfuse_valkey_port
      valkey_password_key = local.langfuse_valkey_password_key

      s3_storage_provider   = var.langfuse_s3_storage_provider
      s3_bucket             = var.langfuse_s3_bucket
      s3_region             = var.langfuse_s3_region
      s3_endpoint           = var.langfuse_s3_endpoint
      s3_force_path_style   = var.langfuse_s3_force_path_style
      s3_static_credentials = local.langfuse_s3_static_credentials
    })
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [
    kubernetes_secret_v1.langfuse_server_secrets,
    kubernetes_secret_v1.langfuse_keypair,
    kubernetes_stateful_set_v1.langfuse_valkey,
    kubernetes_service_v1.langfuse_valkey,
    helm_release.clickhouse_operator,
    kubectl_manifest.langfuse_clickhouse_keeper,
    # The CR is only accepted here, not serving; the chart's own wait below is
    # what actually gates the migration on ClickHouse being reachable.
    kubectl_manifest.langfuse_clickhouse,
    helm_release.ingress_nginx,
    kubectl_manifest.letsencrypt_cluster_issuer,
    kubectl_manifest.selfsigned_cluster_issuer,
  ]
}

resource "kubectl_manifest" "langfuse_virtualservice" {
  count = var.enable_llm_observability && local.use_istio_gateway ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "VirtualService"
    metadata = {
      name      = "langfuse"
      namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
    }
    spec = {
      hosts    = [var.llm_observability_hostname]
      gateways = ["${local.istio_ingress_ns}/${local.istio_public_gateway_name}"]
      http = [
        {
          route = [
            {
              destination = {
                host = "${local.langfuse_web_service}.${kubernetes_namespace_v1.langfuse[0].metadata[0].name}.svc.cluster.local"
                port = { number = 3000 }
              }
            }
          ]
        }
      ]
    }
  })

  depends_on = [
    helm_release.langfuse,
    kubectl_manifest.istio_public_gateway,
  ]
}

output "langfuse_admin_password" {
  description = "Password of the Langfuse admin user created during headless initialization"
  value       = var.enable_llm_observability ? random_password.langfuse_init_user[0].result : null
  sensitive   = true
}
