###
# One-time migration of Ingresses left over from ingress-nginx
###

# The GoodData.CN org controller creates Organization Ingresses at runtime from a
# ConfigMap template, and it does not restart when the Helm values change. Existing
# Ingresses can therefore keep `ingressClassName: nginx` after the switch to Traefik,
# and nothing would serve them. This Job rewrites only those Ingresses. It does
# nothing on fresh installs or when no Ingress uses the nginx class.
#
# The Job runs in the Traefik namespace because the GoodData.CN namespace may have
# Istio sidecar injection, which keeps a Job pod from completing.

resource "kubernetes_service_account_v1" "ingress_class_migration" {
  count = local.use_traefik ? 1 : 0

  metadata {
    name      = "ingress-class-migration"
    namespace = kubernetes_namespace_v1.ingress[0].metadata[0].name
  }
}

resource "kubernetes_role_v1" "ingress_class_migration" {
  count = local.use_traefik ? 1 : 0

  metadata {
    name      = "ingress-class-migration"
    namespace = kubernetes_namespace_v1.gdcn.metadata[0].name
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "ingress_class_migration" {
  count = local.use_traefik ? 1 : 0

  metadata {
    name      = "ingress-class-migration"
    namespace = kubernetes_namespace_v1.gdcn.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.ingress_class_migration[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.ingress_class_migration[0].metadata[0].name
    namespace = kubernetes_service_account_v1.ingress_class_migration[0].metadata[0].namespace
  }
}

resource "kubernetes_job_v1" "ingress_class_migration" {
  count = local.use_traefik ? 1 : 0

  metadata {
    name      = "ingress-class-migration"
    namespace = kubernetes_namespace_v1.ingress[0].metadata[0].name
  }

  spec {
    backoff_limit = 4

    template {
      metadata {}

      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account_v1.ingress_class_migration[0].metadata[0].name

        image_pull_secrets {
          name = local.dhi_pull_secret_name
        }

        container {
          name = "migrate"
          # The -compat variant is the DHI kubectl image that ships /bin/sh.
          # renovate: datasource=docker depName=dhi.io/kubectl
          image = "${local.dhi_registry}/kubectl:1.35.10-compat"

          command = ["/bin/sh", "-ec", join("\n", [
            "ns='${var.gdcn_namespace}'",
            "names=$(kubectl get ingress -n \"$ns\" -o jsonpath='{range .items[?(@.spec.ingressClassName==\"nginx\")]}{.metadata.name}{\"\\n\"}{end}')",
            "for name in $names; do",
            "  echo \"Moving Ingress $ns/$name from nginx to ${local.resolved_ingress_class_name}\"",
            "  kubectl patch ingress \"$name\" -n \"$ns\" --type=merge -p '{\"spec\":{\"ingressClassName\":\"${local.resolved_ingress_class_name}\"}}'",
            "done",
            "echo 'Ingress class migration done'",
          ])]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    helm_release.gooddata_cn,
    kubernetes_role_binding_v1.ingress_class_migration,
    module.dhi_pull,
  ]
}
