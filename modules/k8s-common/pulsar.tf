###
# Deploy Apache Pulsar to Kubernetes
###

locals {
  pulsar_namespace = "pulsar"
}

resource "kubernetes_namespace_v1" "pulsar" {
  metadata {
    name = local.pulsar_namespace
    labels = local.use_istio_gateway ? {
      "istio-injection" = "enabled"
    } : null
  }
}

resource "kubectl_manifest" "peerauth_pulsar_strict" {
  count = local.use_istio_gateway ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata   = { name = "default", namespace = local.pulsar_namespace }
    spec       = { mtls = { mode = "STRICT" } }
  })

  depends_on = [
    kubernetes_namespace_v1.pulsar,
    helm_release.istiod,
  ]
}

resource "helm_release" "pulsar" {
  name             = "pulsar"
  repository       = "https://pulsar.apache.org/charts"
  chart            = "pulsar"
  namespace        = local.pulsar_namespace
  create_namespace = false
  version          = var.helm_pulsar_version
  wait             = true
  wait_for_jobs    = true
  timeout          = 1800

  values = compact([
    yamlencode({
      defaultPulsarImageRepository = "${var.registry_dockerio}/apachepulsar/pulsar"
      components = {
        functions      = false
        proxy          = false
        toolset        = false
        pulsar_manager = false
      }
      zookeeper = {
        podManagementPolicy          = "OrderedReady"
        podMonitor                   = { enabled = false }
        restartPodsOnConfigMapChange = true
      }
      bookkeeper = {
        podMonitor                   = { enabled = false }
        restartPodsOnConfigMapChange = true
        configData                   = { nettyMaxFrameSizeBytes = "10485760" }
      }
      autorecovery = {
        podMonitor                   = { enabled = false }
        restartPodsOnConfigMapChange = true
      }
      broker = {
        podMonitor                   = { enabled = false }
        restartPodsOnConfigMapChange = true
        configData = {
          subscriptionExpirationTimeMinutes = "5"
          systemTopicEnabled                = "true"
          topicLevelPoliciesEnabled         = "true"
        }
      }
      proxy                   = { podMonitor = { enabled = false } }
      "kube-prometheus-stack" = { enabled = false }
    }),
    local.use_istio_gateway ? templatefile("${path.module}/templates/pulsar-istio.tftpl", {}) : null,
    templatefile("${path.module}/templates/pulsar-size-${var.size_profile}.yaml.tftpl", {})
  ])

  depends_on = [
    kubernetes_namespace_v1.pulsar,
    helm_release.istiod,
  ]
}
