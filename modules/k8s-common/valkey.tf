###
# Dedicated single-node Valkey for Langfuse (event queue + cache). Written as
# plain Kubernetes objects because every packaged Valkey chart pulls Bitnami.
###

locals {
  langfuse_valkey_name = "langfuse-valkey"

  # Consumed by langfuse.tf as redis.host / redis.port. join() over the splat
  # keeps this expression valid while the feature flag is off (no namespace).
  langfuse_valkey_host = "${local.langfuse_valkey_name}.${join("", kubernetes_namespace_v1.langfuse[*].metadata[0].name)}.svc.cluster.local"
  langfuse_valkey_port = 6379

  langfuse_valkey_labels = {
    "app.kubernetes.io/name"      = "valkey"
    "app.kubernetes.io/instance"  = "langfuse"
    "app.kubernetes.io/component" = "cache"
  }

  # Authenticated valkey-cli ping; the password stays in the env, never in argv.
  langfuse_valkey_probe = ["sh", "-c", "valkey-cli --no-auth-warning -a \"$VALKEY_PASSWORD\" ping | grep -q PONG"]
}

resource "kubernetes_stateful_set_v1" "langfuse_valkey" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = local.langfuse_valkey_name
    namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
    labels    = local.langfuse_valkey_labels
  }

  spec {
    replicas     = 1
    service_name = local.langfuse_valkey_name

    selector {
      match_labels = local.langfuse_valkey_labels
    }

    template {
      metadata {
        labels = local.langfuse_valkey_labels
      }

      spec {
        # uid 999 / gid 1000 are the valkey user in the upstream image; fs_group
        # makes the PVC writable so the entrypoint never needs root.
        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 1000
          fs_group        = 1000
        }

        container {
          name  = "valkey"
          image = "${var.registry_dockerio}/valkey/valkey:8.1.9-alpine"

          # Image entrypoint is kept, so args start with the server binary.
          # noeviction is required by Langfuse: evicting drops queued events.
          args = [
            "valkey-server",
            "--requirepass", "$(VALKEY_PASSWORD)",
            "--maxmemory-policy", "noeviction",
            "--appendonly", "yes",
          ]

          port {
            name           = "valkey"
            container_port = local.langfuse_valkey_port
          }

          env {
            name = "VALKEY_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.langfuse_secret_name
                key  = local.langfuse_valkey_password_key
              }
            }
          }

          # CPU is flat: Valkey is memory-bound at this scale.
          resources {
            requests = {
              cpu    = "100m"
              memory = local.langfuse_mem.valkey.request
            }
            limits = {
              cpu    = "500m"
              memory = local.langfuse_mem.valkey.limit
            }
          }

          readiness_probe {
            exec {
              command = local.langfuse_valkey_probe
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          liveness_probe {
            exec {
              command = local.langfuse_valkey_probe
            }
            initial_delay_seconds = 30
            period_seconds        = 20
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.gdcn_storage_class != "" ? var.gdcn_storage_class : null

        resources {
          requests = {
            storage = local.langfuse_disk.valkey
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret_v1.langfuse_server_secrets,
  ]
}

resource "kubernetes_service_v1" "langfuse_valkey" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = local.langfuse_valkey_name
    namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
    labels    = local.langfuse_valkey_labels
  }

  spec {
    # Headless: this is the StatefulSet's governing Service, so it has to publish
    # per-pod DNS rather than a single VIP.
    cluster_ip = "None"
    selector   = local.langfuse_valkey_labels

    port {
      name        = "valkey"
      port        = local.langfuse_valkey_port
      target_port = "valkey"
    }
  }
}
