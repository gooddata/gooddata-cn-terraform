###
# Deploy ingress-nginx to Kubernetes for Azure
###

resource "kubernetes_namespace" "ingress" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress.metadata[0].name
  version    = var.helm_ingress_nginx_version

  # Values to configure Azure Load Balancer and exposure
  values = [<<-EOF
controller:
  replicaCount: 2
  image:
    registry: ${var.registry_k8sio}

  admissionWebhooks:
    patch:
      image:
        registry: ${var.registry_k8sio}

  config:
    allow-snippet-annotations: "true"

    # Disable strict path validation, to work around a bug in ingress-nginx
    # https://github.com/kubernetes/ingress-nginx/issues/11176
    strict-validate-path-type: "false"

    client-body-buffer-size: "1m"
    client-body-timeout: "180"
    large-client-header-buffers: "4 32k"
    client-header-buffer-size: "32k"
    proxy-buffer-size: "16k"
    brotli-types: application/vnd.gooddata.api+json application/xml+rss application/atom+xml
      application/javascript application/x-javascript application/json application/rss+xml
      application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json
      application/xhtml+xml application/xml font/opentype image/svg+xml image/x-icon
      text/css text/javascript text/plain text/x-component
    enable-brotli: 'true'
    use-gzip: "true"
    gzip-types: application/vnd.gooddata.api+json application/xml+rss application/atom+xml
        application/javascript application/x-javascript application/json application/rss+xml
        application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json
        application/xhtml+xml application/xml font/opentype image/svg+xml image/x-icon
        text/css text/javascript text/plain text/x-component

  addHeaders:
    Permission-Policy: geolocation 'none'; midi 'none'; sync-xhr 'none';
      microphone 'none'; camera 'none'; magnetometer 'none'; gyroscope 'none';
      fullscreen 'none'; payment 'none';
    Strict-Transport-Security: "max-age=31536000; includeSubDomains"

  service:
    type: LoadBalancer
    annotations:
      # Azure Load Balancer annotations
      service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz"
      service.beta.kubernetes.io/azure-load-balancer-internal: "false"
      service.beta.kubernetes.io/azure-load-balancer-resource-group: "${var.resource_group_name}"
      service.beta.kubernetes.io/azure-pip-name: "${var.deployment_name}-ingress-pip"
      service.beta.kubernetes.io/azure-pip-tags: "Project=${var.deployment_name}"
      service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "4"
EOF
  ]

  depends_on = [
    kubernetes_namespace.ingress
  ]
}

# Get the external IP assigned to the nginx ingress LoadBalancer
data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = kubernetes_namespace.ingress.metadata[0].name
  }

  depends_on = [helm_release.ingress_nginx]
}

output "ingress_external_ip" {
  description = "External IP address assigned to the nginx ingress LoadBalancer"
  value       = try(data.kubernetes_service.ingress_nginx.status[0].load_balancer[0].ingress[0].ip, "")
}
