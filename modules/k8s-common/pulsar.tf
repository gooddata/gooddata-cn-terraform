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

  values = [<<-EOF
defaultPulsarImageRepository: ${var.registry_dockerio}/apachepulsar/pulsar-all

components:
  functions: false
  proxy: false
  toolset: false
  pulsar_manager: false

zookeeper:
  replicaCount: ${var.pulsar_zookeeper_replica_count}
  podManagementPolicy: OrderedReady
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
  volumes:
    data:
      name: data
      size: 2Gi

bookkeeper:
  replicaCount: ${var.pulsar_bookkeeper_replica_count}
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
  resources:
    requests:
      cpu: 0.2
      memory: 128Mi
  volumes:
    journal:
      name: journal
      size: 5Gi
    ledgers:
      name: ledgers
      size: 5Gi
  configData:
    nettyMaxFrameSizeBytes: "10485760"

autorecovery:
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
  configData:
    BOOKIE_MEM: >
      -Xms64m -Xmx128m -XX:MaxDirectMemorySize=128m
broker:
  replicaCount: ${var.pulsar_broker_replica_count}
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
  resources:
    requests:
      cpu: 0.2
      memory: 256Mi
  configData:
    PULSAR_MEM: >
      -Xms128m -Xmx256m -XX:MaxDirectMemorySize=128m
    managedLedgerDefaultEnsembleSize: "1"
    managedLedgerDefaultWriteQuorum: "1"
    managedLedgerDefaultAckQuorum: "1"
    subscriptionExpirationTimeMinutes: "5"
    systemTopicEnabled: "true"
    topicLevelPoliciesEnabled: "true"

proxy:
  podMonitor:
    enabled: false

kube-prometheus-stack:
  enabled: false

EOF
  ]

  depends_on = [
    kubernetes_namespace.pulsar,
    helm_release.istio_ingress_gateway,
  ]
}
