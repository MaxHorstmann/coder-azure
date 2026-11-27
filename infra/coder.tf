# Kubernetes resources Coder needs before its Helm chart is installed.
# See https://coder.com/docs/install/server/kubernetes/

resource "kubernetes_namespace_v1" "coder" {
  metadata {
    name = "coder"
  }

  # Cluster-admin for the identity running Terraform must exist before any
  # Kubernetes API call.
  depends_on = [azurerm_role_assignment.aks_cluster_admin]
}

# Database URL for coderd, referenced from the Helm values as
# CODER_PG_CONNECTION_URL -> secretKeyRef { name: coder-db-url, key: url }.
resource "kubernetes_secret_v1" "coder_db_url" {
  metadata {
    name      = "coder-db-url"
    namespace = kubernetes_namespace_v1.coder.metadata[0].name
  }

  data = {
    url = format(
      "postgres://%s:%s@%s:5432/%s?sslmode=require",
      azurerm_postgresql_flexible_server.main.administrator_login,
      random_password.postgres_admin.result,
      azurerm_postgresql_flexible_server.main.fqdn,
      azurerm_postgresql_flexible_server_database.coder.name,
    )
  }
}

locals {
  coder_access_url = "http://${var.coder_dns_label}.${var.location}.cloudapp.azure.com"
}

# Step 4 of the install guide: install Coder with Helm.
resource "helm_release" "coder" {
  name       = "coder"
  namespace  = kubernetes_namespace_v1.coder.metadata[0].name
  repository = "https://helm.coder.com/v2"
  chart      = "coder"
  version    = var.coder_chart_version

  # Waits for the pod to be ready (LoadBalancer IP + DB migrations).
  wait    = true
  timeout = 600

  values = [yamlencode({
    coder = {
      env = [
        {
          name = "CODER_PG_CONNECTION_URL"
          valueFrom = {
            secretKeyRef = {
              name = kubernetes_secret_v1.coder_db_url.metadata[0].name
              key  = "url"
            }
          }
        },
        { name = "CODER_ACCESS_URL", value = local.coder_access_url },
        { name = "CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE", value = "false" },
      ]

      service = {
        type = "LoadBalancer"
        annotations = {
          # Free DNS name on the AKS-managed public IP.
          "service.beta.kubernetes.io/azure-dns-label-name" = var.coder_dns_label
        }
      }

      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }
  })]
}
