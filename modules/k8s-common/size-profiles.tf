###
# Cloud-agnostic observability sizing for the shared module. These values are
# the same across AWS/Azure/local at a given tier, so they live here once and
# the environment selects a tier by name via var.observability_size. Only the
# observability stack (no per-tier Helm chart) is sized here; GoodData.CN,
# Pulsar, and AI Lake sizing is selected by var.gdcn_size / var.pulsar_size /
# var.ai_lake_size_profile against templates/*-size-<tier>.yaml.tftpl and
# starrocks.tf, not this file.
#
# Observability CPU is intentionally left flat per-service (these components are
# memory-bound, not CPU-bound, at our scale). The disk values are StatefulSet
# volumeClaimTemplates — immutable, so they apply only at PVC creation; a live
# resize is a manual operation and shrinking is never supported.
###

locals {
  # Keyed by the tier the environment passes as var.observability_size.
  size_profiles = {
    dev = {
      observability = {
        memory = {
          prometheus = { request = "256Mi", limit = "1Gi" }
          loki       = { request = "256Mi", limit = "1Gi" }
          tempo      = { request = "128Mi", limit = "512Mi" }
          grafana    = { request = "128Mi", limit = "512Mi" }
          promtail   = { request = "64Mi", limit = "256Mi" }
        }
        disk = {
          # Loki/Tempo are object-storage backed (only a small WAL PVC remains,
          # see obs_wal_disk); Prometheus stays PVC-backed.
          prometheus = "5Gi"
        }
        # Per-tenant Tempo trace-ingestion limits. dev uses Tempo's defaults.
        tempo_ingestion = {
          rate_limit_bytes = 15000000 # 15 MB/s
          burst_size_bytes = 20000000 # 20 MB
        }
      }
    }
    prod-small = {
      observability = {
        memory = {
          prometheus = { request = "512Mi", limit = "2Gi" }
          loki       = { request = "512Mi", limit = "2Gi" }
          tempo      = { request = "256Mi", limit = "1Gi" }
          grafana    = { request = "256Mi", limit = "1Gi" }
          promtail   = { request = "128Mi", limit = "256Mi" }
        }
        disk = {
          # Loki/Tempo are object-storage backed (only a small WAL PVC remains,
          # see obs_wal_disk); Prometheus stays PVC-backed.
          prometheus = "10Gi"
        }
        # Raised above Tempo defaults to stop RATE_LIMITED drops at peak.
        tempo_ingestion = {
          rate_limit_bytes = 30000000 # 30 MB/s
          burst_size_bytes = 45000000 # 45 MB
        }
      }
    }
    prod-large = {
      observability = {
        memory = {
          prometheus = { request = "1Gi", limit = "4Gi" }
          loki       = { request = "1Gi", limit = "4Gi" }
          # Higher request/limit gives the single-binary Tempo headroom for the
          # raised ingestion limits below, so the larger live-trace buffer does
          # not OOM under peak trace volume.
          tempo    = { request = "1Gi", limit = "3Gi" }
          grafana  = { request = "256Mi", limit = "1Gi" }
          promtail = { request = "128Mi", limit = "512Mi" }
        }
        disk = {
          # Loki/Tempo are object-storage backed (retention lives in the bucket;
          # only a small fixed WAL PVC remains, see obs_wal_disk). Prometheus
          # stays PVC-backed (no native object-store mode without Thanos/Mimir).
          prometheus = "100Gi"
        }
        tempo_ingestion = {
          rate_limit_bytes = 50000000 # 50 MB/s
          burst_size_bytes = 75000000 # 75 MB
        }
      }
    }
  }

  # Valid workload size tiers = the keys of the size_profiles map above; used by
  # the gdcn_size / observability_size / pulsar_size variable validations.
  workload_size_tiers = keys(local.size_profiles)

  obs_profile         = local.size_profiles[var.observability_size]
  obs_mem             = local.obs_profile.observability.memory
  obs_disk            = local.obs_profile.observability.disk
  obs_tempo_ingestion = local.obs_profile.observability.tempo_ingestion
}
