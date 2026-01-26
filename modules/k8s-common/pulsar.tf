###
# Deploy Apache Pulsar to Kubernetes
###

locals {
  pulsar_namespace = "pulsar"
}

resource "kubernetes_namespace" "pulsar" {
  metadata {
    name = local.pulsar_namespace
    labels = var.enable_istio ? {
      "istio-injection" = "enabled"
    } : null
  }
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

  values = [
    <<-EOF
defaultPulsarImageRepository: ${var.registry_dockerio}/apachepulsar/pulsar

components:
  functions: false
  proxy: false
  toolset: false
  pulsar_manager: false

zookeeper:
  podManagementPolicy: OrderedReady
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true

bookkeeper:
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
  configData:
    nettyMaxFrameSizeBytes: "10485760"

autorecovery:
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
broker:
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
  configData:
    subscriptionExpirationTimeMinutes: "5"
    systemTopicEnabled: "true"
    topicLevelPoliciesEnabled: "true"

proxy:
  podMonitor:
    enabled: false

kube-prometheus-stack:
  enabled: false

EOF
    ,
    templatefile("${path.module}/templates/pulsar-size-${var.size_profile}.yaml.tftpl", {})
  ]

  depends_on = [
    kubernetes_namespace.pulsar,
    helm_release.istio_ingress_gateway,
  ]
}
