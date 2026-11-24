# Prometheus scrapes under Istio STRICT mTLS: Istio metrics merging.
#
# The namespaces gdcn, pulsar and langfuse enforce STRICT mTLS, and no port has a PERMISSIVE
# exemption. Prometheus (observability namespace) does not scrape the application metrics port
# of a pod. It scrapes the merged metrics endpoint of the Istio sidecar: port 15020, path
# /stats/prometheus.
#
# - Port 15020 is served by pilot-agent. The sidecar iptables rules do not intercept it
#   (inbound exclude list 15090,15021,<statusPort>), so the PeerAuthentication does not apply and
#   the scrape is plain HTTP.
# - pilot-agent merges the Envoy metrics with the application metrics. It reads the application
#   endpoint from the pod annotations prometheus.io/scrape, prometheus.io/port and
#   prometheus.io/path. The charts set them, and gdcn-metrics-merge.yaml.tftpl sets them for the
#   GoodData.CN components whose chart does not.
# - Merging is on for the mesh (meshConfig.enablePrometheusMerge in istio.tf).
# - Port 15020 is not a declared container port, so the PodMonitor selects the application
#   container by the name of its metrics port (as the chart PodMonitors do), and the relabeling
#   below changes only the target port to 15020. The labels container, pod and namespace of the
#   metrics stay the same (the dashboards and the KEDA triggers use container and namespace).
#
# The PodMonitors of the charts are off in this mode: they scrape the application port directly,
# and STRICT mTLS resets that connection. The charts are the source for the port names.
#
# If a chart sets NetworkPolicies (networkPolicy.enabled), they must allow port 15020 from the
# observability namespace.
locals {
  metrics_merge_enabled = var.enable_observability && local.use_istio_gateway

  istio_merged_metrics_port = 15020
  istio_merged_metrics_path = "/stats/prometheus"

  # Changes only the port of the pod target to the merged metrics port (IPv4 and IPv6 addresses).
  metrics_merge_relabel_port = {
    action       = "replace"
    sourceLabels = ["__address__"]
    regex        = "(.+?)(?::\\d+)?"
    targetLabel  = "__address__"
    replacement  = "$1:${local.istio_merged_metrics_port}"
  }

  # Same relabeling as the Pulsar chart PodMonitor: Pulsar dashboards use the pod labels and
  # job = component.
  metrics_merge_pulsar_relabelings = [
    { action = "labelmap", regex = "__meta_kubernetes_pod_label_(.+)" },
    { action = "replace", sourceLabels = ["__meta_kubernetes_namespace"], targetLabel = "kubernetes_namespace" },
    { action = "replace", sourceLabels = ["__meta_kubernetes_pod_label_component"], targetLabel = "job" },
    { action = "replace", sourceLabels = ["__meta_kubernetes_pod_name"], targetLabel = "kubernetes_pod_name" },
  ]

  # One PodMonitor per entry. "ports" are the names of the container ports that carry the
  # application metrics; a pod has at most one of them.
  metrics_merge_monitors = local.metrics_merge_enabled ? merge(
    {
      # GoodData.CN chart: Spring components use "actuator", the other components "metrics",
      # custom etcd "etcd-metrics". job = component (app.kubernetes.io/component).
      gdcn = {
        namespace      = var.gdcn_namespace
        selector       = { matchLabels = { "app.kubernetes.io/name" = "gooddata-cn" } }
        job_label      = "app.kubernetes.io/component"
        ports          = ["actuator", "metrics", "etcd-metrics"]
        interval       = "20s"
        scrape_timeout = "10s"
        honor_labels   = false
        relabelings    = []
      }
      # redis_exporter sidecar of the redis-ha subchart.
      gdcn-redis-ha = {
        namespace      = var.gdcn_namespace
        selector       = { matchLabels = { app = "redis-ha", release = "gooddata-cn" } }
        job_label      = null
        ports          = ["exporter-port"]
        interval       = "20s"
        scrape_timeout = "10s"
        honor_labels   = false
        relabelings    = []
      }
      # Pulsar chart: zookeeper, bookie, autorecovery ("recovery") and broker, port "http".
      pulsar = {
        namespace = local.pulsar_namespace
        selector = {
          matchLabels      = { app = "pulsar" }
          matchExpressions = [{ key = "component", operator = "In", values = ["zookeeper", "bookie", "recovery", "broker"] }]
        }
        job_label      = null
        ports          = ["http"]
        interval       = "60s"
        scrape_timeout = "60s"
        honor_labels   = true
        relabelings    = local.metrics_merge_pulsar_relabelings
      }
    },
    var.enable_llm_observability ? {
      # ClickHouse of Langfuse: port "prometheus" (9363), published by the operator.
      langfuse-clickhouse = {
        namespace      = kubernetes_namespace_v1.langfuse[0].metadata[0].name
        selector       = { matchLabels = { "clickhouse.com/cluster" = local.langfuse_clickhouse_cr_name } }
        job_label      = null
        ports          = ["prometheus"]
        interval       = "30s"
        scrape_timeout = "10s"
        honor_labels   = false
        relabelings    = []
      }
    } : {}
  ) : {}
}

resource "kubectl_manifest" "prometheus_merged_podmonitor" {
  for_each = local.metrics_merge_monitors

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata   = { name = "istio-merged-${each.key}", namespace = each.value.namespace }
    spec = merge(
      {
        namespaceSelector = { matchNames = [each.value.namespace] }
        selector          = each.value.selector
        podMetricsEndpoints = [
          for p in each.value.ports : merge(
            {
              port          = p
              path          = local.istio_merged_metrics_path
              scheme        = "http"
              interval      = each.value.interval
              scrapeTimeout = each.value.scrape_timeout
              relabelings   = concat(each.value.relabelings, [local.metrics_merge_relabel_port])
            },
            each.value.honor_labels ? { honorLabels = true } : {}
          )
        ]
      },
      each.value.job_label != null ? { jobLabel = each.value.job_label } : {}
    )
  })

  depends_on = [
    helm_release.istiod,
    helm_release.kube_prometheus_stack,
    kubernetes_namespace_v1.gdcn,
    kubernetes_namespace_v1.pulsar,
  ]
}
