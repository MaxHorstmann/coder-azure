resource "random_password" "postgres_admin" {
  length           = 32
  special          = true
  override_special = "-_~"
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                = "psql-${var.name}-${substr(md5("${var.subscription_id}-${var.name}"), 0, 6)}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  version             = var.postgres_version
  sku_name            = var.postgres_sku_name
  storage_mb          = var.postgres_storage_mb
  auto_grow_enabled   = true

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = false

  # Private access only, via VNet integration.
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  administrator_login    = var.postgres_admin_username
  administrator_password = random_password.postgres_admin.result

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    # Azure picks an availability zone on create; don't fight it afterwards.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "coder" {
  name      = "coder"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
