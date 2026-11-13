###
# Hardening values for the GoodData.CN chart. They are rendered before
# gdcn_helm_extra_values, so a value set there always wins. Settings that the
# module already applies on every deployment (license and Tink keyset in
# Secrets, per-service Postgres users, telemetry off, tools.replicaCount 0,
# STRICT mTLS under the Istio gateway) live in their own files.
###

locals {
  # Mirrors the chart's own values-restricted.yaml (4.15.1) without its
  # placeholder labels. restrictedPodSecurity covers the GoodData.CN pods;
  # the third-party redis-ha and qdrant subcharts need their own keys.
  gdcn_hardened_values = {
    restrictedPodSecurity = { enabled = true }

    redis-ha = {
      securityContext = {
        runAsUser           = 1000
        runAsGroup          = 1000
        runAsNonRoot        = true
        fsGroup             = 1000
        fsGroupChangePolicy = "OnRootMismatch"
        supplementalGroups  = [1000]
      }
      containerSecurityContext = {
        runAsUser                = 1000
        runAsGroup               = 1000
        runAsNonRoot             = true
        readOnlyRootFilesystem   = true
        allowPrivilegeEscalation = false
        seccompProfile           = { type = "RuntimeDefault" }
        capabilities             = { drop = ["ALL"] }
      }
    }

    # Rendered only when AI features deploy qdrant. The root chown init
    # container cannot run as non-root, so fsGroup takes over its job.
    qdrant = {
      podSecurityContext = {
        runAsNonRoot        = true
        runAsUser           = 1000
        runAsGroup          = 2000
        fsGroup             = 3000
        fsGroupChangePolicy = "OnRootMismatch"
        supplementalGroups  = [3000]
      }
      containerSecurityContext = {
        capabilities   = { drop = ["ALL"] }
        seccompProfile = { type = "RuntimeDefault" }
      }
      updateVolumeFsOwnership = false
      livenessProbe           = { enabled = true }
    }
  }

  gdcn_next = var.gdcn_hardening_next_release

  # Each key is rendered only when its input is set, so the default plan is
  # unchanged. Charts ignore keys they do not know (no values schema).
  gdcn_hardening_option_values = { for k, v in {
    deployDexIdP = var.gdcn_deploy_dex ? null : false

    settings = var.gdcn_embedding_origins == null ? null : {
      embeddingOrigins = var.gdcn_embedding_origins
    }

    service = local.gdcn_next.db_ssl_mode == null && local.gdcn_next.db_ssl_root_cert == null ? null : {
      postgres = { for pk, pv in {
        sslMode = local.gdcn_next.db_ssl_mode
        sslRootCert = local.gdcn_next.db_ssl_root_cert == null ? null : {
          secretName = local.gdcn_next.db_ssl_root_cert.secret_name
          key        = local.gdcn_next.db_ssl_root_cert.key
        }
      } : pk => pv if pv != null }
    }

    global = local.gdcn_next.fips_mode == null && local.gdcn_next.fips_allow_non_fips_host == null && local.gdcn_next.aws_use_fips_endpoint == null ? null : {
      for gk, gv in {
        fips = local.gdcn_next.fips_mode == null && local.gdcn_next.fips_allow_non_fips_host == null ? null : {
          for fk, fv in {
            mode             = local.gdcn_next.fips_mode
            allowNonFipsHost = local.gdcn_next.fips_allow_non_fips_host
          } : fk => fv if fv != null
        }
        aws = local.gdcn_next.aws_use_fips_endpoint == null ? null : {
          useFipsEndpoint = local.gdcn_next.aws_use_fips_endpoint
        }
      } : gk => gv if gv != null
    }

    exportBuilder = local.gdcn_next.export_egress_mode == null && local.gdcn_next.export_egress_allowed_hosts == null ? null : {
      egress = { for ek, ev in {
        mode         = local.gdcn_next.export_egress_mode
        allowedHosts = local.gdcn_next.export_egress_allowed_hosts
      } : ek => ev if ev != null }
    }
  } : k => v if v != null }

  gdcn_hardening_values = compact([
    var.gdcn_hardened ? yamlencode(local.gdcn_hardened_values) : null,
    length(local.gdcn_hardening_option_values) > 0 ? yamlencode(local.gdcn_hardening_option_values) : null,
  ])
}
