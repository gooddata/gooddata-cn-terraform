###
# Deploy Apache Pulsar to Kubernetes
###

resource "helm_release" "pulsar" {
  name             = "pulsar"
  repository       = "https://pulsar.apache.org/charts"
  chart            = "pulsar"
  namespace        = "pulsar"
  create_namespace = true
  version          = var.helm_pulsar_version
  timeout          = 1800

  values = [<<-EOF
defaultPulsarImageRepository: ${var.registry_dockerio}/apachepulsar/pulsar-all

components:
  functions: false
  proxy: false
  toolset: false
  pulsar_manager: false

zookeeper:
  replicaCount: 1
  podManagementPolicy: OrderedReady
  podMonitor:
    enabled: false
  restartPodsOnConfigMapChange: true
  volumes:
    data:
      name: data
      size: 2Gi

bookkeeper:
  replicaCount: 1
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
  replicaCount: 1
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
}
