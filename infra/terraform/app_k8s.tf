locals {
  mongodb_uri = "mongodb://${var.mongo_app_user}:${var.mongo_app_password}@${aws_instance.mongo.private_ip}:27017/${var.mongo_db_name}?authSource=${var.mongo_db_name}"
}

variable "app_image_uri" {
  type        = string
  description = "ECR image URI with tag (e.g., <repo>:<sha>)"
}

# ---------------------------
# Ingress Controller (nginx) -> provisions AWS Load Balancer
# ---------------------------
resource "helm_release" "nginx_ingress" {
  count            = var.deploy_k8s ? 1 : 0
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
        }
      }
    })
  ]
}

# ---------------------------
# Kubernetes objects (gated)
# ---------------------------
resource "kubernetes_namespace_v1" "wizapp" {
  count = var.deploy_k8s ? 1 : 0

  metadata {
    name = "wizapp"
  }
}

resource "kubernetes_service_account_v1" "wizapp" {
  count = var.deploy_k8s ? 1 : 0

  metadata {
    name      = "wizapp-sa"
    namespace = kubernetes_namespace_v1.wizapp[0].metadata[0].name
  }
}

# Intentional weakness: cluster-admin binding
resource "kubernetes_cluster_role_binding_v1" "wizapp_admin" {
  count = var.deploy_k8s ? 1 : 0

  metadata {
    name = "wizapp-cluster-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.wizapp[0].metadata[0].name
    namespace = kubernetes_namespace_v1.wizapp[0].metadata[0].name
  }
}

resource "kubernetes_secret_v1" "mongo" {
  count = var.deploy_k8s ? 1 : 0

  metadata {
    name      = "mongo-conn"
    namespace = kubernetes_namespace_v1.wizapp[0].metadata[0].name
  }

  data = {
    MONGODB_URI = local.mongodb_uri
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "wizapp" {
  count = var.deploy_k8s ? 1 : 0

  metadata {
    name      = "wizapp"
    namespace = kubernetes_namespace_v1.wizapp[0].metadata[0].name
    labels    = { app = "wizapp" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "wizapp" }
    }

    template {
      metadata { labels = { app = "wizapp" } }

      spec {
        service_account_name = kubernetes_service_account_v1.wizapp[0].metadata[0].name

        container {
          name  = "wizapp"
          image = var.app_image_uri

          port { container_port = 3000 }

          env {
            name = "MONGODB_URI"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mongo[0].metadata[0].name
                key  = "MONGODB_URI"
              }
            }
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress]
}

resource "kubernetes_service_v1" "wizapp" {
  count = var.deploy_k8s ? 1 : 0

  metadata {
    name      = "wizapp"
    namespace = kubernetes_namespace_v1.wizapp[0].metadata[0].name
  }

  spec {
    selector = { app = "wizapp" }

    port {
      port        = 80
      target_port = 3000
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "wizapp" {
  count = var.deploy_k8s ? 1 : 0

  metadata {
    name      = "wizapp"
    namespace = kubernetes_namespace_v1.wizapp[0].metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.wizapp[0].metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress]
}
