# DNS + public IP for Coder.
#
# The `coder_domain` subdomain (e.g. coder.maxhorstmann.net) is delegated from
# the parent domain's registrar to this Azure DNS zone via NS records (see the
# `coder_dns_name_servers` output). Terraform then owns all records below it,
# and cert-manager can solve Let's Encrypt DNS-01 challenges (wildcard certs).

resource "azurerm_dns_zone" "coder" {
  name                = var.coder_domain
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# Static IP for Coder's LoadBalancer service, so DNS never goes stale when the
# Kubernetes Service is recreated.
resource "azurerm_public_ip" "coder" {
  name                = "pip-${var.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# AKS needs rights on the resource group to attach an IP that lives outside
# its node resource group.
resource "azurerm_role_assignment" "aks_network_rg" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_dns_a_record" "coder" {
  name                = "@"
  zone_name           = azurerm_dns_zone.coder.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.coder.ip_address]
  tags                = var.tags
}

# Wildcard for Coder workspace apps (CODER_WILDCARD_ACCESS_URL).
resource "azurerm_dns_a_record" "coder_wildcard" {
  name                = "*"
  zone_name           = azurerm_dns_zone.coder.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.coder.ip_address]
  tags                = var.tags
}
