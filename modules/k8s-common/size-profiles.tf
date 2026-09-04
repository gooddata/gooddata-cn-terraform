###
# Cloud-agnostic sizing for the observability and Langfuse stacks, by tier. Disk
# values are volumeClaimTemplates: applied at PVC creation only, never shrink.
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
      langfuse = {
        # web/worker are the only stateless deployments; ClickHouse, Keeper and
        # Valkey stay single-node at every tier.
        replicas = {
          web    = 1
          worker = 1
        }
        memory = {
          web        = { request = "512Mi", limit = "1Gi" }
          worker     = { request = "512Mi", limit = "2Gi" }
          clickhouse = { request = "1Gi", limit = "4Gi" }
          # Keeper only holds replication/DDL metadata for one shard.
          clickhouse_keeper = { request = "256Mi", limit = "512Mi" }
          valkey            = { request = "128Mi", limit = "512Mi" }
        }
        disk = {
          clickhouse        = "20Gi"
          clickhouse_keeper = "5Gi"
          # Valkey is a BullMQ queue, so the PVC only holds in-flight events.
          valkey = "2Gi"
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
      langfuse = {
        # Two of each so a node drain or rolling update does not drop the UI or
        # in-flight trace ingestion.
        replicas = {
          web    = 2
          worker = 2
        }
        memory = {
          web               = { request = "512Mi", limit = "2Gi" }
          worker            = { request = "1Gi", limit = "3Gi" }
          clickhouse        = { request = "2Gi", limit = "8Gi" }
          clickhouse_keeper = { request = "512Mi", limit = "1Gi" }
          valkey            = { request = "256Mi", limit = "1Gi" }
        }
        disk = {
          clickhouse        = "100Gi"
          clickhouse_keeper = "10Gi"
          valkey            = "5Gi"
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

  # Valid workload size tiers = the keys of the size_profiles map above, used by
  # the *_size variable validations.
  workload_size_tiers = keys(local.size_profiles)

  obs_profile         = local.size_profiles[var.observability_size]
  obs_mem             = local.obs_profile.observability.memory
  obs_disk            = local.obs_profile.observability.disk
  obs_tempo_ingestion = local.obs_profile.observability.tempo_ingestion

  # Langfuse has no prod-large spec, so the larger tiers use prod-small.
  langfuse_profile  = local.size_profiles[var.observability_size == "dev" ? "dev" : "prod-small"]
  langfuse_replicas = local.langfuse_profile.langfuse.replicas
  langfuse_mem      = local.langfuse_profile.langfuse.memory
  langfuse_disk     = local.langfuse_profile.langfuse.disk
}
