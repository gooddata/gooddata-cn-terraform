###
# ClickHouse for Langfuse: the ClickHouse-maintained operator plus a
# single-shard, single-replica ClickHouseCluster and its KeeperCluster.
###

locals {
  # Both CRs are named "langfuse"; the operator suffixes every object it owns
  # with its role, so the two kinds never collide.
  langfuse_clickhouse_cr_name = "langfuse"

  # The operator publishes clients on the headless Service <cr>-clickhouse-headless.
  # join() over the splat keeps this valid while the feature flag is off.
  langfuse_clickhouse_host = "${local.langfuse_clickhouse_cr_name}-clickhouse-headless.${join("", kubernetes_namespace_v1.langfuse[*].metadata[0].name)}.svc.cluster.local"

  # Fixed by the operator on every ClickHouse pod and its headless Service.
  langfuse_clickhouse_http_port   = 8123
  langfuse_clickhouse_native_port = 9000

  langfuse_clickhouse_username = "langfuse"

  # Keeper and server must stay on the same ClickHouse release.
  langfuse_clickhouse_image_tag = "25.8-alpine"

  # Langfuse migrates its schema in place and never issues CREATE DATABASE, so
  # its tables live in the built-in database.
  langfuse_clickhouse_database = "default"

  # Carries the Langfuse user's password from the shared secret into the server
  # config, so the password itself never appears in the CR.
  langfuse_clickhouse_password_env = "CLICKHOUSE_LANGFUSE_PASSWORD"
}

# Admin (`default` user) password. Kept separate from the Langfuse user so the
# admin account is not shared with the application.
resource "random_password" "langfuse_clickhouse_admin" {
  count = var.enable_llm_observability ? 1 : 0

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "langfuse_clickhouse_admin" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = "langfuse-clickhouse-admin"
    namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
  }

  data = {
    password = random_password.langfuse_clickhouse_admin[0].result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# Installed in the Langfuse namespace so the operator shares its mesh identity
# with ClickHouse; the admission webhook is off because cert-manager is optional.
resource "helm_release" "clickhouse_operator" {
  count = var.enable_llm_observability ? 1 : 0

  name       = "clickhouse-operator"
  repository = "oci://ghcr.io/clickhouse"
  chart      = "clickhouse-operator-helm"
  version    = var.helm_clickhouse_operator_version
  namespace  = kubernetes_namespace_v1.langfuse[0].metadata[0].name

  values = [
    yamlencode({
      controller = {
        watchNamespaces = [kubernetes_namespace_v1.langfuse[0].metadata[0].name]
      }
      certManager = { enabled = false }
      webhook     = { enabled = false }

      # Plain HTTP metrics: the chart only mounts a metrics certificate when
      # cert-manager issues one, and the mesh already encrypts the scrape.
      metrics    = { secure = false }
      prometheus = { enabled = var.enable_observability }
    })
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  # The chart renders a ServiceMonitor when observability is on, so the
  # Prometheus operator CRDs have to exist first.
  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}

# Keeper backs replication and distributed DDL and is required by the
# ClickHouseCluster CR; one replica is enough for a single-node cluster.
resource "kubectl_manifest" "langfuse_clickhouse_keeper" {
  count = var.enable_llm_observability ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "clickhouse.com/v1alpha1"
    kind       = "KeeperCluster"
    metadata = {
      name      = local.langfuse_clickhouse_cr_name
      namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
    }
    spec = {
      replicas = 1

      containerTemplate = {
        image = {
          repository = "${var.registry_dockerio}/clickhouse/clickhouse-keeper"
          tag        = local.langfuse_clickhouse_image_tag
        }
        resources = {
          requests = { cpu = "100m", memory = local.langfuse_mem.clickhouse_keeper.request }
          limits   = { cpu = "500m", memory = local.langfuse_mem.clickhouse_keeper.limit }
        }
      }

      dataVolumeClaimSpec = merge(
        {
          accessModes = ["ReadWriteOnce"]
          resources   = { requests = { storage = local.langfuse_disk.clickhouse_keeper } }
        },
        local.gdcn_storage_class_override
      )
    }
  })

  depends_on = [
    helm_release.clickhouse_operator,
  ]
}

resource "kubectl_manifest" "langfuse_clickhouse" {
  count = var.enable_llm_observability ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "clickhouse.com/v1alpha1"
    kind       = "ClickHouseCluster"
    metadata = {
      name      = local.langfuse_clickhouse_cr_name
      namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
    }
    spec = {
      shards   = 1
      replicas = 1

      keeperClusterRef = {
        name = local.langfuse_clickhouse_cr_name
      }

      containerTemplate = {
        image = {
          repository = "${var.registry_dockerio}/clickhouse/clickhouse-server"
          tag        = local.langfuse_clickhouse_image_tag
        }
        env = [
          {
            name = local.langfuse_clickhouse_password_env
            valueFrom = {
              secretKeyRef = {
                name = local.langfuse_secret_name
                key  = local.langfuse_clickhouse_password_key
              }
            }
          }
        ]
        resources = {
          requests = { cpu = "250m", memory = local.langfuse_mem.clickhouse.request }
          limits   = { cpu = "2", memory = local.langfuse_mem.clickhouse.limit }
        }
      }

      dataVolumeClaimSpec = merge(
        {
          accessModes = ["ReadWriteOnce"]
          resources   = { requests = { storage = local.langfuse_disk.clickhouse } }
        },
        local.gdcn_storage_class_override
      )

      settings = {
        defaultUserPassword = {
          secret = {
            name = kubernetes_secret_v1.langfuse_clickhouse_admin[0].metadata[0].name
            key  = "password"
          }
        }

        # Merged into the operator's users config. Langfuse runs its own
        # migrations, so it owns every object in its database.
        extraUsersConfig = {
          users = {
            (local.langfuse_clickhouse_username) = {
              profile  = "default"
              quota    = "default"
              networks = { ip = "::/0" }
              password = [
                {
                  "@from_env"             = local.langfuse_clickhouse_password_env
                  "@hide_in_preprocessed" = true
                }
              ]
              grants = [
                { query = "GRANT ALL ON ${local.langfuse_clickhouse_database}.*" },
                { query = "GRANT SHOW ON *.*" },
                { query = "GRANT SELECT ON system.*" },
              ]
            }
          }
        }
      }
    }
  })

  depends_on = [
    helm_release.clickhouse_operator,
    kubectl_manifest.langfuse_clickhouse_keeper,
    kubernetes_secret_v1.langfuse_server_secrets,
  ]
}

# ClickHouse serves its own metrics on port 9363, which the operator publishes on
# the headless Service; the operator ships no ServiceMonitor for the server.
resource "kubectl_manifest" "langfuse_clickhouse_servicemonitor" {
  count = var.enable_llm_observability && var.enable_observability ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "langfuse-clickhouse"
      namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
    }
    spec = {
      namespaceSelector = {
        matchNames = [kubernetes_namespace_v1.langfuse[0].metadata[0].name]
      }
      selector = {
        matchLabels = {
          "app"                    = "${local.langfuse_clickhouse_cr_name}-clickhouse"
          "clickhouse.com/cluster" = local.langfuse_clickhouse_cr_name
        }
      }
      endpoints = [
        {
          port          = "prometheus"
          path          = "/metrics"
          interval      = "30s"
          scrapeTimeout = "10s"
        }
      ]
    }
  })

  depends_on = [
    kubectl_manifest.langfuse_clickhouse,
    helm_release.kube_prometheus_stack,
  ]
}
