resource "azurerm_resource_group" "main" {
  # Region in the name so a location change replaces every resource cleanly.
  name     = "rg-${var.name}-${var.location}"
  location = var.location
  tags     = var.tags
}
