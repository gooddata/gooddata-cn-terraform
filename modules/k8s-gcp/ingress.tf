###
# Deploy ingress-nginx to Kubernetes for GCP
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
    strict-validate-path-type: "false"
    client-body-buffer-size: "1m"
    client-body-timeout: "180"
    large-client-header-buffers: "4 32k"
    client-header-buffer-size: "32k"
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
    annotations:
      cloud.google.com/load-balancer-type: "External"
      networking.gke.io/load-balancer-type: "External"
    loadBalancerIP: ${var.ingress_static_ip_address}
EOF
  ]

  depends_on = [
    kubernetes_namespace.ingress
  ]
}
