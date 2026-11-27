output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL, for setting up workload identity federation later."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "postgres_fqdn" {
  description = "Private FQDN of the PostgreSQL server (resolvable from inside the VNet)."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_database" {
  value = azurerm_postgresql_flexible_server_database.coder.name
}

output "postgres_admin_username" {
  value = azurerm_postgresql_flexible_server.main.administrator_login
}

output "coder_pg_connection_url" {
  description = "Connection URL for CODER_PG_CONNECTION_URL. Retrieve with: terraform output -raw coder_pg_connection_url"
  sensitive   = true
  value = format(
    "postgres://%s:%s@%s:5432/%s?sslmode=require",
    azurerm_postgresql_flexible_server.main.administrator_login,
    random_password.postgres_admin.result,
    azurerm_postgresql_flexible_server.main.fqdn,
    azurerm_postgresql_flexible_server_database.coder.name,
  )
}

output "coder_dns_name_servers" {
  description = "Add these as NS records for the coder_domain host at the parent domain's registrar."
  value       = azurerm_dns_zone.coder.name_servers
}

output "coder_public_ip" {
  value = azurerm_public_ip.coder.ip_address
}
