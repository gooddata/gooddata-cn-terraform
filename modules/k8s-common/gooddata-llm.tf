###
# Register an LLM provider for GoodData.CN organizations (optional)
#
# When gdcn_bedrock_llm is set (and AI features are on), a one-shot Job upserts
# the llmProvider entity and activates it (ACTIVE_LLM_PROVIDER) for every
# organization in gdcn_orgs. It authenticates with each org's bootstrap admin
# token and talks to the metadata-api service directly with a Host header, so
# it works in all ingress modes without external DNS or TLS.
###

locals {
  llm_bootstrap_enabled = var.enable_ai_features && var.gdcn_bedrock_llm != null && length(local.managed_orgs_by_id) > 0

  llm_provider_id = local.llm_bootstrap_enabled ? var.gdcn_bedrock_llm.provider_id : ""

  llm_credentials = var.gdcn_bedrock_llm_credentials != null ? var.gdcn_bedrock_llm_credentials : {
    access_key_id     = ""
    secret_access_key = ""
    session_token     = ""
  }

  llm_provider_payload = local.llm_bootstrap_enabled ? jsonencode({
    data = {
      id   = var.gdcn_bedrock_llm.provider_id
      type = "llmProvider"
      attributes = {
        defaultModelId = var.gdcn_bedrock_llm.default_model_id
        models         = [for m in var.gdcn_bedrock_llm.models : { family = m.family, id = m.id }]
        providerConfig = {
          type   = "AWS_BEDROCK"
          region = var.gdcn_bedrock_llm.region
          auth = merge(
            {
              type            = "ACCESS_KEY"
              accessKeyId     = local.llm_credentials.access_key_id
              secretAccessKey = local.llm_credentials.secret_access_key
            },
            local.llm_credentials.session_token != "" ? { sessionToken = local.llm_credentials.session_token } : {}
          )
        }
      }
    }
  }) : ""

  llm_setting_payload = local.llm_bootstrap_enabled ? jsonencode({
    data = {
      id   = "active_llm_provider"
      type = "organizationSetting"
      attributes = {
        type    = "ACTIVE_LLM_PROVIDER"
        content = { id = var.gdcn_bedrock_llm.provider_id, type = "llmProvider" }
      }
    }
  }) : ""

  llm_orgs_file = join("", [
    for id, org in local.managed_orgs_by_id :
    "${org.hostname} ${base64encode("${org.admin_user}:bootstrap:${random_password.gdcn_org_admin_password[id].result}")}\n"
  ])
}

resource "kubernetes_secret_v1" "gdcn_llm_bootstrap" {
  count = local.llm_bootstrap_enabled ? 1 : 0

  metadata {
    name      = "gdcn-llm-bootstrap"
    namespace = var.gdcn_namespace
  }

  data = {
    "configure.sh" = templatefile("${path.module}/templates/gdcn-llm-bootstrap.sh.tftpl", {
      provider_id = local.llm_provider_id
    })
    "provider.json" = local.llm_provider_payload
    "setting.json"  = local.llm_setting_payload
    orgs            = local.llm_orgs_file
  }

  lifecycle {
    precondition {
      condition     = var.gdcn_bedrock_llm_credentials != null
      error_message = "gdcn_bedrock_llm_credentials must be set when gdcn_bedrock_llm is set."
    }
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}

# In istio mode the job pod runs without a sidecar (the sidecar cannot route
# the foreign org Host header), so metadata-api must accept plaintext on 9007.
# API-level Bearer auth still applies; all other ports stay on namespace STRICT.
resource "kubectl_manifest" "peerauth_metadata_api_llm" {
  count = local.use_istio_gateway && local.llm_bootstrap_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata   = { name = "gdcn-metadata-api-llm-bootstrap", namespace = var.gdcn_namespace }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "gooddata-cn"
          "app.kubernetes.io/instance"  = "gooddata-cn"
          "app.kubernetes.io/component" = "metadataApi"
        }
      }
      portLevelMtls = { "9007" = { mode = "PERMISSIVE" } }
    }
  })

  depends_on = [
    kubernetes_namespace_v1.gdcn,
    helm_release.istiod,
  ]
}

resource "kubernetes_job_v1" "gdcn_llm_bootstrap" {
  count = local.llm_bootstrap_enabled ? 1 : 0

  metadata {
    name      = "gdcn-llm-bootstrap"
    namespace = var.gdcn_namespace
  }

  spec {
    backoff_limit = 4

    template {
      metadata {
        annotations = {
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "configure"
          image = "${var.registry_dockerio}/curlimages/curl:8.11.1"

          command = ["/bin/sh", "/config/configure.sh"]

          env {
            name = "METADATA_API_URL"
            # Service name follows the fixed "gooddata-cn" Helm release name.
            value = "http://gooddata-cn-metadata-api.${var.gdcn_namespace}.svc.cluster.local:9007"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 65534

            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            limits = {
              cpu    = "50m"
              memory = "64Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
          }
        }

        volume {
          name = "config"

          secret {
            secret_name = kubernetes_secret_v1.gdcn_llm_bootstrap[0].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "20m"
    update = "20m"
  }

  lifecycle {
    # Job specs are effectively immutable in the kubernetes provider (template
    # changes patch nothing), so a config change must replace the Job to re-run.
    replace_triggered_by = [kubernetes_secret_v1.gdcn_llm_bootstrap[0].data]
  }

  depends_on = [
    helm_release.gooddata_cn,
    kubectl_manifest.gdcn_organization,
    kubectl_manifest.peerauth_metadata_api_llm,
  ]
}
