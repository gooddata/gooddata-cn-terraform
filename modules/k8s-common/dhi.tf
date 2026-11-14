###
# Docker Hardened Images (DHI): registry, Helm login and image pull secret
###

locals {
  dhi_registry         = "dhi.io"
  dhi_pull_secret_name = "dhi-pull-secret" # the default of modules/dhi-pull-secret

  # Every namespace that runs DHI images needs the pull secret. With Istio, the
  # injector adds the secret to each injected pod, so injected namespaces need it too.
  dhi_pull_namespaces = distinct(concat(
    local.use_istio_gateway ? [local.istio_system_ns, local.istio_ingress_ns] : [],
    # Redis HA, the socat sidecar and the Postgres bootstrap Jobs run in the GoodData.CN namespace.
    [var.gdcn_namespace],
    local.use_istio_gateway ? [local.pulsar_namespace] : [],
    local.use_istio_gateway && var.enable_ai_lake ? [local.starrocks_namespace] : [],
    var.enable_observability ? ["observability"] : [],
    var.enable_llm_observability ? [local.langfuse_namespace] : [],
    local.use_cert_manager ? ["cert-manager"] : [],
    # HTTP-01 solver pods run in the namespace of each Ingress that requests a certificate.
    var.tls_mode == "letsencrypt" ? [var.gdcn_namespace] : [],
    var.tls_mode == "letsencrypt" && var.enable_observability ? ["observability"] : [],
    var.tls_mode == "letsencrypt" && var.enable_llm_observability ? [local.langfuse_namespace] : [],
    local.use_traefik ? [local.traefik_namespace] : [],
    var.enable_gdcn_autoscaling ? ["keda"] : [],
  ))
}

module "dhi_pull" {
  source = "../dhi-pull-secret"

  username     = var.dhi_username
  access_token = var.dhi_access_token
  namespaces   = { for ns in local.dhi_pull_namespaces : ns => ns }
  consumers    = "platform components are"

  depends_on = [
    kubernetes_namespace_v1.istio_system,
    kubernetes_namespace_v1.istio_ingress,
    kubernetes_namespace_v1.gdcn,
    kubernetes_namespace_v1.pulsar,
    kubernetes_namespace_v1.starrocks,
    kubernetes_namespace_v1.observability,
    kubernetes_namespace_v1.langfuse,
    kubernetes_namespace_v1.cert-manager,
    kubernetes_namespace_v1.ingress,
    kubernetes_namespace_v1.keda,
  ]
}
