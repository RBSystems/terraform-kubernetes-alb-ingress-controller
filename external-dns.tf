// https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/aws.md
resource "aws_iam_role" "external_dns" {
  name                  = "${var.aws_resource_name_prefix}${var.k8s_cluster_name}-${local.external_dns_name}"
  description           = "Permissions required by the Kubernetes ExternalDNS pod"
  path                  = local.aws_iam_path_prefix
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.eks_oidc_assume_role.json
  tags                  = var.aws_tags
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets"
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name        = "${var.aws_resource_name_prefix}${var.k8s_cluster_name}-${local.external_dns_name}"
  description = "Permissions that are required to manage AWS Route53 entries"
  path        = local.aws_iam_path_prefix
  policy      = data.aws_iam_policy_document.external_dns.json
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

resource "kubernetes_service_account" "external_dns" {
  metadata {
    name      = local.external_dns_name
    namespace = var.k8s_namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
    }

    labels = {
      "app.kubernetes.io/name"       = local.external_dns_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  automount_service_account_token = true
}

resource "kubernetes_cluster_role" "external_dns" {
  metadata {
    name = local.external_dns_name

    labels = {
      "app.kubernetes.io/name"       = local.external_dns_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["get", "watch", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list"]
  }

  rule {
    api_groups = ["extensions"]
    resources  = ["ingresses"]
    verbs      = ["get", "watch", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["watch", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "external_dns" {
  metadata {
    name = local.external_dns_name

    labels = {
      "app.kubernetes.io/name"       = local.external_dns_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.external_dns.metadata.0.name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.external_dns.metadata.0.name
    namespace = kubernetes_service_account.external_dns.metadata.0.namespace
  }
}

resource "kubernetes_deployment" "external_dns" {
  depends_on = [kubernetes_cluster_role_binding.external_dns]

  metadata {
    name      = local.external_dns_name
    namespace = var.k8s_namespace

    labels = {
      "app.kubernetes.io/name"       = local.external_dns_name
      "app.kubernetes.io/version"    = "v${var.external_dns_version}"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.external_dns_name
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = local.external_dns_name
          "app.kubernetes.io/version" = "v${var.external_dns_version}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.external_dns.metadata.0.name

        container {
          name              = "server"
          image             = "registry.opensource.zalan.do/teapot/external-dns:v${var.external_dns_version}"
          image_pull_policy = "Always"

          args = [
            "--source=service",
            "--source=ingress",
            "--provider=aws",
            "--aws-zone-type=public",
            "--registry=txt",
            "--txt-owner-id=${var.aws_resource_name_prefix}${var.k8s_cluster_name}-${var.k8s_namespace}"
          ]

          volume_mount {
            mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
            name       = kubernetes_service_account.external_dns.default_secret_name
            read_only  = true
          }

          port {
            name           = "metrics"
            container_port = 7979
            protocol       = "TCP"
          }

          readiness_probe {
            http_get {
              scheme = "HTTP"
              port   = "metrics"
              path   = "/healthz"
            }

            initial_delay_seconds = 45
            period_seconds        = 60
            timeout_seconds       = 3
          }

          liveness_probe {
            http_get {
              scheme = "HTTP"
              port   = "metrics"
              path   = "/healthz"
            }

            initial_delay_seconds = 60
            period_seconds        = 60
            timeout_seconds       = 3
          }
        }

        volume {
          name = kubernetes_service_account.external_dns.default_secret_name

          secret {
            secret_name = kubernetes_service_account.external_dns.default_secret_name
          }
        }

        // so that ExternalDNS can read the serviceaccount token
        security_context {
          fs_group = 65534
        }
      }
    }
  }
}
