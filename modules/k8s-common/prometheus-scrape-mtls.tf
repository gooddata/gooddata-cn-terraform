# Prometheus scrapes under STRICT mTLS.
#
# The namespaces gdcn, pulsar and langfuse enforce STRICT mTLS. Prometheus (observability namespace,
# with sidecar) reaches the metrics ports through pod IPs. Istio does not know these ports as service
# ports, so the Prometheus sidecar sends plain text (PassthroughCluster). The pod sidecar then resets
# the connection, and the metrics are missing (also the KEDA triggers that query Prometheus).
#
# The PodMonitors that the Helm charts create cannot use TLS (no scheme/tlsConfig value), so the
# Istio "scrape with certificates" pattern is not possible. Instead, each STRICT namespace gets one
# workload-scoped PeerAuthentication that keeps STRICT and sets PERMISSIVE on the metrics ports only.
# The namespace itself stays STRICT.
locals {
  # Metrics (PodMonitor/ServiceMonitor) container ports of the GoodData.CN chart (gooddata-cn 4.15).
  # Ports that no pod has are ignored. Add a port here when a chart version adds a metrics port.
  prometheus_scrape_gdcn_ports = [
    5558,  # dex
    6581,  # export-controller
    8080,  # etcd-metrics (component customEtcd)
    8081,  # organization-controller
    9001,  # afm-exec-api
    9008,  # metadata-api
    9012,  # calcique
    9041,  # result-cache
    9061,  # scan-model
    9093,  # api-gateway
    9098,  # automation
    9099,  # gateway-forge
    9101,  # sql-executor
    9129,  # export-builder
    9132,  # tabular-exporter
    9138,  # mcp-server
    9202,  # api-gw
    16101, # quiver
  ]

  # Not split per component: two workload-scoped PeerAuthentications that match the same pod conflict
  # (Istio applies only one of them), so a separate etcd entry for 8080 would break its scrape.

  # Pulsar chart, one entry per component so that each pod gets only its own metrics port:
  # "http" port 8000 on zookeeper, bookie and autorecovery; 8080 on the broker only (the broker also
  # serves the Pulsar admin REST API on 8080: see the note in the module documentation).
  prometheus_scrape_pulsar_ports = {
    zookeeper = [8000]
    bookie    = [8000]
    recovery  = [8000]
    broker    = [8080]
  }

  # ClickHouse of Langfuse: operator-published "prometheus" port.
  prometheus_scrape_langfuse_clickhouse_ports = [9363]

  prometheus_scrape_peerauth = var.enable_observability && local.use_istio_gateway ? merge(
    {
      gdcn = {
        namespace = var.gdcn_namespace
        selector  = { "app.kubernetes.io/name" = "gooddata-cn" }
        ports     = local.prometheus_scrape_gdcn_ports
      }
    },
    {
      for c, ports in local.prometheus_scrape_pulsar_ports : "pulsar-${c}" => {
        namespace = local.pulsar_namespace
        selector  = { app = "pulsar", component = c }
        ports     = ports
      }
    },
    var.enable_llm_observability ? {
      langfuse-clickhouse = {
        namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
        selector  = { "clickhouse.com/cluster" = local.langfuse_clickhouse_cr_name }
        ports     = local.prometheus_scrape_langfuse_clickhouse_ports
      }
    } : {}
  ) : {}
}

resource "kubectl_manifest" "peerauth_prometheus_scrape" {
  for_each = local.prometheus_scrape_peerauth

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "PeerAuthentication"
    metadata   = { name = "prometheus-scrape-${each.key}", namespace = each.value.namespace }
    spec = {
      selector = { matchLabels = each.value.selector }
      mtls     = { mode = "STRICT" }
      portLevelMtls = {
        for p in each.value.ports : tostring(p) => { mode = "PERMISSIVE" }
      }
    }
  })

  depends_on = [
    helm_release.istiod,
    kubernetes_namespace_v1.gdcn,
    kubernetes_namespace_v1.pulsar,
  ]
}
