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
