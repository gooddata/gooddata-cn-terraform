resource "kubernetes_config_map_v1" "grafana_dashboard_gooddata_cn_overall_health" {
  count = var.enable_observability ? 1 : 0

  metadata {
    name      = "grafana-dashboard-gooddata-cn-overall-health"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "GoodData-CN"
    }
  }

  data = {
    "gooddata-cn-overall-health.json" = file("${path.module}/dashboards/gooddata-cn-overall-health.json")
  }

  depends_on = [helm_release.grafana]
}
