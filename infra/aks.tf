data "azurerm_client_config" "current" {}

# User-assigned identity for the AKS control plane, so we can grant it rights
# on the VNet before the cluster is created.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-${var.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  node_resource_group = "rg-${var.name}-aks-nodes"
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free" # no uptime SLA; switch to "Standard" for production

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  local_account_disabled            = true
  role_based_access_control_enabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.aks_admin_group_object_ids
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # Single node pool running both system pods and Coder; the autoscaler adds
  # nodes as workspaces need them.
  default_node_pool {
    name                        = "default"
    vm_size                     = var.aks_node_vm_size
    vnet_subnet_id              = azurerm_subnet.aks.id
    auto_scaling_enabled        = true
    min_count                   = var.aks_node_min_count
    max_count                   = var.aks_node_max_count
    os_disk_type                = "Managed"
    os_disk_size_gb             = 64
    temporary_name_for_rotation = "defaulttmp"

    upgrade_settings {
      max_surge = "33%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.aks_network]

  lifecycle {
    ignore_changes = [
      # Managed by the autoscaler.
      default_node_pool[0].node_count,
    ]
  }
}

# Cluster-admin via Azure RBAC for the admin groups and for the identity running
# Terraform (CI will need it later to install Coder via Helm).
resource "azurerm_role_assignment" "aks_cluster_admin" {
  for_each = toset(concat(var.aks_admin_group_object_ids, [data.azurerm_client_config.current.object_id]))

  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
