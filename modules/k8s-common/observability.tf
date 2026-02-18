resource "kubernetes_namespace_v1" "observability" {
  count = var.enable_observability ? 1 : 0

  metadata {
    name = "observability"
    labels = local.use_istio_gateway ? {
      "istio-injection" = "enabled"
    } : null
  }
}

resource "helm_release" "prometheus" {
  count = var.enable_observability ? 1 : 0

  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = var.helm_prometheus_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  values = [
    yamlencode({
      server = {
        retention = "2d"
        persistentVolume = {
          size = "5Gi"
        }
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "1Gi"
          }
        }
      }
      alertmanager = { enabled = false }
      pushgateway  = { enabled = false }
      nodeExporter = { enabled = true }
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
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "1Gi"
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
      config = {
        clients = [{
          url = "http://loki.observability.svc.cluster.local:3100/loki/api/v1/push"
        }]
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "256Mi"
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
      }
      persistence = {
        enabled = true
        size    = "5Gi"
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "512Mi"
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
      persistence = {
        enabled = true
        size    = "1Gi"
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "512Mi"
        }
      }
      "grafana.ini" = {
        server = {
          root_url = "https://${var.observability_hostname}/"
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
              url       = "http://prometheus-server.observability.svc.cluster.local"
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
                  datasourceUid = "loki"
                }
                streamingEnabled = {
                  search = false
                }
              }
            }
          ]
        }
      }
      ingress = {
        enabled          = !local.use_istio_gateway
        ingressClassName = local.resolved_ingress_class_name
        annotations = merge(
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

  depends_on = [helm_release.prometheus, helm_release.loki, helm_release.tempo]
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
