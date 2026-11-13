###
# Self-hosted OpenStreetMap basemap (geo_basemap_provider = "protomaps")
#
# Self-contained: no external map service at runtime, works air-gapped. One
# Deployment (gdc-basemap) serves vector tiles from a PMTiles archive on a PVC,
# plus glyphs and sprites from its image, plus the MapLibre style from a
# ConfigMap. api-gw reaches it through the chart's CustomLocation plugin and
# proxies every tile, glyph and sprite, so map traffic stays in the cluster.
#
# The archive comes from one of:
# - geo_protomaps_source_url: a Job cuts it to geo_protomaps_bbox and
#   geo_protomaps_max_zoom (default: the public Protomaps daily build; for an
#   air-gapped install, a mirror on an internal http(s):// or s3:// URL).
#   Each extract (source, area and zoom) has its own PVC, named with the extract hash. The
#   volume is ReadWriteOnce and the running server holds the previous one, so a replacement
#   Job must not need that volume: it fills a new PVC and can run on any node. The server
#   (strategy Recreate) then switches to the new PVC, and Terraform deletes the old PVC.
# - geo_protomaps_existing_claim: a PVC that already holds basemap.pmtiles
#   (customer-provided file); no Job runs.
###

locals {
  protomaps_enabled   = var.geo_basemap_provider == "protomaps"
  protomaps_name      = "gdcn-basemap"
  protomaps_base_url  = "http://${local.protomaps_name}.${var.gdcn_namespace}.svc.cluster.local:8080"
  protomaps_style_url = "${local.protomaps_base_url}/style/style.json"
  protomaps_claim     = var.geo_protomaps_existing_claim != "" ? var.geo_protomaps_existing_claim : "${local.protomaps_name}-${local.protomaps_extract_hash}"
  protomaps_labels    = { "app.kubernetes.io/name" = local.protomaps_name, "app.kubernetes.io/part-of" = "gooddata-cn" }
  # The Service selects only the server, never the extract pod.
  protomaps_server_labels  = merge(local.protomaps_labels, { "app.kubernetes.io/component" = "server" })
  protomaps_extract_labels = merge(local.protomaps_labels, { "app.kubernetes.io/component" = "extract" })
  # Protomaps "light" flavor, generated with @protomaps/basemaps 5.7.2
  # (layers("protomaps", namedFlavor("light"), {lang: "en"})); attribution
  # (Protomaps, OpenStreetMap/ODbL) is in the source.
  protomaps_style = replace(replace(file("${path.module}/files/protomaps-light-style.json"),
  "__BASE__", local.protomaps_base_url), "\"maxzoom\":99999", "\"maxzoom\":${var.geo_protomaps_max_zoom}")
  # A changed source, area or zoom makes a new PVC and a new Job, which build a new archive.
  # Same pull secrets as the GoodData.CN chart (gooddata-cn.tf): the image comes from the gdc-nas build registry.
  protomaps_pull_secrets = concat(
    local.use_internal_registry_auth ? [kubernetes_secret_v1.internal_registry[0].metadata[0].name] : [],
    [local.dhi_pull_secret_name],
  )
  protomaps_extract_hash = substr(sha256(join("|", [var.geo_protomaps_source_url, var.geo_protomaps_bbox, var.geo_protomaps_max_zoom])), 0, 8)
  protomaps_run_extract  = local.protomaps_enabled && var.geo_protomaps_existing_claim == "" && var.geo_protomaps_source_url != ""

  # The extract Job writes the archive that the server reads. On SELinux nodes
  # (for example Bottlerocket) every pod gets its own MCS categories, and the
  # server cannot read the Job's file. Both pods use the same fixed level.
  protomaps_selinux_level = "s0:c117,c842"

  protomaps_security_context = {
    run_as_non_root            = true
    run_as_user                = 65532
    allow_privilege_escalation = false
    read_only_root_filesystem  = true
  }
}

resource "kubernetes_persistent_volume_claim_v1" "protomaps" {
  count = local.protomaps_enabled && var.geo_protomaps_existing_claim == "" ? 1 : 0

  metadata {
    name      = local.protomaps_claim
    namespace = var.gdcn_namespace
    labels    = local.protomaps_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.gdcn_storage_class != "" ? var.gdcn_storage_class : null
    resources {
      requests = { storage = var.geo_protomaps_storage_size }
    }
  }

  # The volume binds when the first pod (the extract Job) mounts it.
  wait_until_bound = false

  # The name changes with the extract hash. Create the new PVC first: the running server still
  # mounts the old one until the Deployment switches, and a PVC in use cannot be deleted.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [kubernetes_namespace_v1.gdcn]
}

resource "kubernetes_job_v1" "protomaps_extract" {
  count = local.protomaps_run_extract ? 1 : 0

  metadata {
    name      = "${local.protomaps_name}-extract-${local.protomaps_extract_hash}"
    namespace = var.gdcn_namespace
    labels    = local.protomaps_labels
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = local.protomaps_extract_labels
        # One-off download; a sidecar would keep the Job from completing.
        annotations = { "sidecar.istio.io/inject" = "false" }
      }

      spec {
        restart_policy = "OnFailure"
        dynamic "image_pull_secrets" {
          for_each = local.protomaps_pull_secrets
          content {
            name = image_pull_secrets.value
          }
        }
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          fs_group        = 65532
          seccomp_profile { type = "RuntimeDefault" }
          se_linux_options { level = local.protomaps_selinux_level }
        }

        container {
          name  = "extract"
          image = var.geo_protomaps_image
          args  = ["extract"]

          env {
            name  = "SOURCE_URL"
            value = var.geo_protomaps_source_url
          }
          env {
            name  = "BBOX"
            value = var.geo_protomaps_bbox
          }
          env {
            name  = "MAXZOOM"
            value = tostring(var.geo_protomaps_max_zoom)
          }
          env {
            name  = "FORCE"
            value = "true"
          }

          resources {
            requests = { cpu = "200m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          security_context {
            run_as_non_root            = local.protomaps_security_context.run_as_non_root
            run_as_user                = local.protomaps_security_context.run_as_user
            allow_privilege_escalation = local.protomaps_security_context.allow_privilege_escalation
            read_only_root_filesystem  = local.protomaps_security_context.read_only_root_filesystem
            capabilities { drop = ["ALL"] }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = local.protomaps_claim
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "60m"
    update = "60m"
  }

  depends_on = [kubernetes_persistent_volume_claim_v1.protomaps, module.dhi_pull, kubernetes_secret_v1.internal_registry]
}

resource "kubernetes_config_map_v1" "protomaps_style" {
  count = local.protomaps_enabled ? 1 : 0

  metadata {
    name      = "${local.protomaps_name}-style"
    namespace = var.gdcn_namespace
    labels    = local.protomaps_labels
  }

  data = {
    "style.json" = local.protomaps_style
  }

  depends_on = [kubernetes_namespace_v1.gdcn]
}

resource "kubernetes_deployment_v1" "protomaps" {
  count = local.protomaps_enabled ? 1 : 0

  metadata {
    name      = local.protomaps_name
    namespace = var.gdcn_namespace
    labels    = local.protomaps_labels
  }

  spec {
    replicas = 1
    # ReadWriteOnce volume: the old pod must stop before the new one mounts it.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.protomaps_server_labels
    }

    template {
      metadata {
        labels = local.protomaps_server_labels
        annotations = {
          "checksum/style" = sha256(local.protomaps_style)
          "extract/job"    = local.protomaps_run_extract ? local.protomaps_extract_hash : "none"
        }
      }

      spec {
        dynamic "image_pull_secrets" {
          for_each = local.protomaps_pull_secrets
          content {
            name = image_pull_secrets.value
          }
        }
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          fs_group        = 65532
          seccomp_profile { type = "RuntimeDefault" }
          se_linux_options { level = local.protomaps_selinux_level }
        }

        container {
          name  = "basemap"
          image = var.geo_protomaps_image

          port {
            name           = "http"
            container_port = 8080
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          # Measured during a full dashboard export: 4m CPU, 9 Mi.
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "500m", memory = "128Mi" }
          }

          security_context {
            run_as_non_root            = local.protomaps_security_context.run_as_non_root
            run_as_user                = local.protomaps_security_context.run_as_user
            allow_privilege_escalation = local.protomaps_security_context.allow_privilege_escalation
            read_only_root_filesystem  = local.protomaps_security_context.read_only_root_filesystem
            capabilities { drop = ["ALL"] }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
            read_only  = true
          }
          volume_mount {
            name       = "style"
            mount_path = "/style"
            read_only  = true
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = local.protomaps_claim
            read_only  = true
          }
        }
        volume {
          name = "style"
          config_map {
            name = kubernetes_config_map_v1.protomaps_style[0].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_rollout = true

  lifecycle {
    precondition {
      condition     = var.geo_protomaps_image != ""
      error_message = "geo_basemap_provider = \"protomaps\" needs geo_protomaps_image (the gdc-basemap image from gdc-nas tools/basemap-image)."
    }
    precondition {
      condition     = var.geo_protomaps_existing_claim != "" || var.geo_protomaps_source_url != ""
      error_message = "geo_basemap_provider = \"protomaps\" needs geo_protomaps_source_url (extract Job) or geo_protomaps_existing_claim (PVC with basemap.pmtiles)."
    }
  }

  depends_on = [kubernetes_job_v1.protomaps_extract, kubernetes_persistent_volume_claim_v1.protomaps, module.dhi_pull, kubernetes_secret_v1.internal_registry]
}

resource "kubernetes_service_v1" "protomaps" {
  count = local.protomaps_enabled ? 1 : 0

  metadata {
    name      = local.protomaps_name
    namespace = var.gdcn_namespace
    labels    = local.protomaps_labels
  }

  spec {
    selector = local.protomaps_server_labels
    port {
      name        = "http"
      port        = 8080
      target_port = "http"
    }
  }

  depends_on = [kubernetes_namespace_v1.gdcn]
}
