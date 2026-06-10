resource "kubernetes_namespace_v1" "observability" {
  count = var.enable_observability ? 1 : 0

  metadata {
    name = "observability"
    labels = local.use_istio_gateway ? {
      "istio-injection" = "enabled"
    } : null
  }
}

locals {
  # Memory requests/limits for the observability stack, scaled by size_profile.
  # CPU is intentionally left flat per-service (metrics show these components are
  # memory-bound, not CPU-bound at our scale). prod-xl mirrors prod-large.
  observability_memory = {
    dev = {
      prometheus = { request = "256Mi", limit = "1Gi" }
      loki       = { request = "256Mi", limit = "1Gi" }
      tempo      = { request = "128Mi", limit = "512Mi" }
      grafana    = { request = "128Mi", limit = "512Mi" }
      promtail   = { request = "64Mi", limit = "256Mi" }
    }
    prod-small = {
      prometheus = { request = "512Mi", limit = "2Gi" }
      loki       = { request = "512Mi", limit = "2Gi" }
      tempo      = { request = "256Mi", limit = "1Gi" }
      grafana    = { request = "256Mi", limit = "1Gi" }
      promtail   = { request = "128Mi", limit = "256Mi" }
    }
    prod-large = {
      prometheus = { request = "1Gi", limit = "4Gi" }
      loki       = { request = "1Gi", limit = "4Gi" }
      # Higher request/limit gives the single-binary Tempo headroom for the
      # raised ingestion limits (see helm_release.tempo overrides) so the
      # larger live-trace buffer does not OOM under peak trace volume.
      tempo    = { request = "1Gi", limit = "3Gi" }
      grafana  = { request = "256Mi", limit = "1Gi" }
      promtail = { request = "128Mi", limit = "512Mi" }
    }
  }

  # prod-xl uses prod-large sizing; fall back to prod-small for any other
  # unmapped profile.
  obs_mem = lookup(
    local.observability_memory,
    var.size_profile == "prod-xl" ? "prod-large" : var.size_profile,
    local.observability_memory["prod-small"],
  )
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_observability ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.helm_kube_prometheus_stack_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  values = [
    yamlencode({
      # Disable components we manage separately
      grafana      = { enabled = false }
      alertmanager = { enabled = false }

      # Cluster-wide visibility
      kubeStateMetrics = { enabled = true }
      nodeExporter     = { enabled = true }

      # Subchart image overrides
      "kube-state-metrics" = {
        image = { registry = var.registry_k8sio }
      }
      "prometheus-node-exporter" = {
        image = { registry = var.registry_quayio }
      }

      prometheusOperator = {
        image = { registry = var.registry_quayio }
        prometheusConfigReloader = {
          image = { registry = var.registry_quayio }
        }
        admissionWebhooks = {
          deployment = {
            image = { registry = var.registry_quayio }
          }
        }
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      prometheus = {
        prometheusSpec = {
          image = { registry = var.registry_quayio }
          externalLabels = {
            cluster_name = var.deployment_name
          }
          retention = var.prometheus_retention_period
          resources = {
            requests = { cpu = "100m", memory = local.obs_mem.prometheus.request }
            limits   = { cpu = "500m", memory = local.obs_mem.prometheus.limit }
          }
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                resources = {
                  requests = { storage = "5Gi" }
                }
              }
            }
          }
          # Discover all PodMonitors/ServiceMonitors cluster-wide, not just
          # those matching the Helm release labels.
          podMonitorSelectorNilUsesHelmValues     = false
          serviceMonitorSelectorNilUsesHelmValues = false
        }
      }
    })
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800
}

resource "helm_release" "loki" {
  count = var.enable_observability ? 1 : 0

  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.helm_loki_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"
      loki = {
        image = { registry = var.registry_dockerio }
        commonConfig = {
          replication_factor = 1
        }
        storage = {
          type = "filesystem"
        }
        schemaConfig = {
          configs = [{
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "filesystem"
            schema       = "v13"
            index = {
              prefix = "index_"
              period = "24h"
            }
          }]
        }
        # Retention is enforced by the compactor loop below. retention_period
        # caps log age; the 5Gi PVC still caps total size, so at high log volume
        # data may be evicted before this period is reached.
        limits_config = {
          retention_period = var.loki_retention_period
        }
        compactor = {
          retention_enabled    = true
          delete_request_store = "filesystem"
        }
        auth_enabled = false
      }
      singleBinary = {
        replicas = 1
        persistence = {
          enabled = true
          size    = "5Gi"
        }
        resources = {
          requests = {
            cpu    = "100m"
            memory = local.obs_mem.loki.request
          }
          limits = {
            cpu    = "500m"
            memory = local.obs_mem.loki.limit
          }
        }
      }
      backend      = { replicas = 0 }
      read         = { replicas = 0 }
      write        = { replicas = 0 }
      chunksCache  = { enabled = false }
      resultsCache = { enabled = false }
      gateway      = { enabled = false }
      minio        = { enabled = false }
      sidecar = {
        image = { registry = var.registry_dockerio }
      }
      lokiCanary = {
        image = { registry = var.registry_dockerio }
      }
      monitoring = {
        selfMonitoring = { enabled = false }
        lokiCanary     = { enabled = false }
      }
      test = { enabled = false }
    })
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800
}

resource "helm_release" "promtail" {
  count = var.enable_observability ? 1 : 0

  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = var.helm_promtail_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  values = [
    yamlencode({
      image = { registry = var.registry_dockerio }
      config = {
        clients = [{
          url = "http://loki.observability.svc.cluster.local:3100/loki/api/v1/push"
        }]
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = local.obs_mem.promtail.request
        }
        limits = {
          cpu    = "200m"
          memory = local.obs_mem.promtail.limit
        }
      }
    })
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [helm_release.loki]
}

resource "helm_release" "tempo" {
  count = var.enable_observability ? 1 : 0

  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = var.helm_tempo_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  values = [
    yamlencode({
      tempo = {
        image = { registry = var.registry_dockerio }
        receivers = {
          jaeger = {
            protocols = {
              grpc           = { endpoint = "0.0.0.0:14250" }
              thrift_binary  = { endpoint = "0.0.0.0:6832" }
              thrift_compact = { endpoint = "0.0.0.0:6831" }
              thrift_http    = { endpoint = "0.0.0.0:14268" }
            }
          }
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
          zipkin = { endpoint = "0.0.0.0:9411" }
        }
        # Trace retention enforced by the block-storage compactor. The 5Gi PVC
        # still caps total size, so traces may be evicted before this period.
        retention = var.tempo_retention_period
        # Raise per-tenant ingestion limits above Tempo's defaults (15MB/s rate,
        # 20MB burst). The defaults were rejecting trace pushes during peak
        # windows with "RATE_LIMITED: ingestion rate limit ... exceeded" errors.
        # Strategy stays "local" (single-binary deployment, no global ring).
        overrides = {
          defaults = {
            ingestion = {
              rate_limit_bytes = 30000000 # 30 MB/s (default: 15 MB/s)
              burst_size_bytes = 45000000 # 45 MB   (default: 20 MB)
            }
          }
        }
      }
      persistence = {
        enabled = true
        size    = "5Gi"
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = local.obs_mem.tempo.request
        }
        limits = {
          cpu    = "200m"
          memory = local.obs_mem.tempo.limit
        }
      }
    })
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800
}

resource "helm_release" "grafana" {
  count = var.enable_observability ? 1 : 0

  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = var.helm_grafana_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  values = [
    yamlencode({
      image                   = { registry = var.registry_dockerio }
      downloadDashboardsImage = { registry = var.registry_dockerio }
      initChownData = {
        image = { registry = var.registry_dockerio }
      }
      deploymentStrategy = {
        type = "Recreate"
      }
      persistence = {
        enabled = true
        size    = "1Gi"
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = local.obs_mem.grafana.request
        }
        limits = {
          cpu    = "200m"
          memory = local.obs_mem.grafana.limit
        }
      }
      "grafana.ini" = {
        server = {
          root_url = "https://${var.observability_hostname}/"
        }
      }

      imageRenderer = {
        enabled  = true
        replicas = 1
        image = {
          registry = var.registry_dockerio
          tag      = "latest"
        }
        env = {
          HTTP_HOST           = "0.0.0.0"
          XDG_CONFIG_HOME     = "/tmp/.chromium"
          XDG_CACHE_HOME      = "/tmp/.chromium"
          RENDERING_ARGS      = "--no-sandbox,--disable-gpu,--window-size=1280x758"
          RENDERING_MODE      = "default"
          IGNORE_HTTPS_ERRORS = "true"
        }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "1Gi" }
        }
      }
      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1
          providers = [{
            name            = "grafana-dashboards-kubernetes"
            orgId           = 1
            folder          = "Kubernetes"
            type            = "file"
            disableDeletion = true
            editable        = true
            options = {
              path = "/var/lib/grafana/dashboards/grafana-dashboards-kubernetes"
            }
          }]
        }
      }
      dashboards = {
        grafana-dashboards-kubernetes = {
          k8s-system-api-server = {
            url   = "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-system-api-server.json"
            token = ""
          }
          k8s-system-coredns = {
            url   = "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-system-coredns.json"
            token = ""
          }
          k8s-views-global = {
            url   = "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-global.json"
            token = ""
          }
          k8s-views-namespaces = {
            url   = "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-namespaces.json"
            token = ""
          }
          k8s-views-nodes = {
            url   = "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-nodes.json"
            token = ""
          }
          k8s-views-pods = {
            url   = "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-pods.json"
            token = ""
          }
        }
      }
      datasources = {
        "datasources.yaml" = {
          apiVersion = 1
          datasources = [
            {
              name      = "Prometheus"
              type      = "prometheus"
              uid       = "prometheus"
              url       = "http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090"
              access    = "proxy"
              isDefault = true
            },
            {
              name   = "Loki"
              type   = "loki"
              uid    = "loki"
              url    = "http://loki.observability.svc.cluster.local:3100"
              access = "proxy"
            },
            {
              name   = "Tempo"
              type   = "tempo"
              uid    = "tempo"
              url    = "http://tempo.observability.svc.cluster.local:3200"
              access = "proxy"
              jsonData = {
                nodeGraph = {
                  enabled = true
                }
                tracesToLogsV2 = {
                  datasourceUid      = "loki"
                  spanStartTimeShift = "-5m"
                  spanEndTimeShift   = "5m"
                  filterByTraceID    = false
                  filterBySpanID     = false
                  customQuery        = true
                  # Every GoodData.CN microservice logs under a single Loki stream
                  # (namespace/app/service_name = gdcn_namespace), while spans carry
                  # per-service service.name values, so no span-tag-to-Loki-label
                  # mapping lines up and the default query has no usable stream
                  # selector. Instead scope to the namespace and match on both the
                  # trace ID and span ID, which GoodData.CN writes into every
                  # structured log line ("traceId":"<id>","spanId":"<id>"). Matching
                  # the span ID narrows "Logs for this span" to the clicked span's
                  # service/operation rather than the whole trace. The $${...}
                  # escapes Grafana provisioning env-var expansion so the Tempo data
                  # source interpolates the IDs at query time.
                  query = "{namespace=\"${var.gdcn_namespace}\"} |= \"$$${__span.traceId}\" |= \"$$${__span.spanId}\""
                }
                streamingEnabled = {
                  search = false
                }
              }
            },
          ]
        }
      }
      sidecar = {
        image = { registry = var.registry_quayio }
        dashboards = {
          enabled          = true
          label            = "grafana_dashboard"
          labelValue       = "1"
          folderAnnotation = "grafana_folder"
          provider = {
            allowUiUpdates            = true
            foldersFromFilesStructure = true
          }
        }
      }
      ingress = {
        enabled          = !local.use_istio_gateway
        ingressClassName = local.resolved_ingress_class_name
        annotations = merge(
          {
            "nginx.ingress.kubernetes.io/proxy-body-size" = "50m"
          },
          local.use_cert_manager ? {
            "cert-manager.io/cluster-issuer" = local.cert_manager_cluster_issuer_name
          } : {},
          var.ingress_annotations_override
        )
        hosts = [var.observability_hostname]
        path  = "/"
        tls = local.use_cert_manager ? [{
          secretName = "grafana-tls"
          hosts      = [var.observability_hostname]
        }] : []
      }
    })
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [helm_release.kube_prometheus_stack, helm_release.loki, helm_release.tempo]
}

resource "kubectl_manifest" "peerauth_observability_strict" {
  count = var.enable_observability && local.use_istio_gateway ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata   = { name = "default", namespace = kubernetes_namespace_v1.observability[0].metadata[0].name }
    spec       = { mtls = { mode = "STRICT" } }
  })

  depends_on = [
    kubernetes_namespace_v1.observability,
    helm_release.istiod,
  ]
}

resource "kubectl_manifest" "grafana_virtualservice" {
  count = var.enable_observability && local.use_istio_gateway ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "VirtualService"
    metadata = {
      name      = "grafana"
      namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
    }
    spec = {
      hosts    = [var.observability_hostname]
      gateways = ["${local.istio_ingress_ns}/${local.istio_public_gateway_name}"]
      http = [
        {
          route = [
            {
              destination = {
                host = "grafana.${kubernetes_namespace_v1.observability[0].metadata[0].name}.svc.cluster.local"
                port = { number = 80 }
              }
            }
          ]
        }
      ]
    }
  })

  depends_on = [
    helm_release.grafana,
    kubectl_manifest.istio_public_gateway,
  ]
}
