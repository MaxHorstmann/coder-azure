variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "name" {
  description = "Base name used as a prefix for all resources."
  type        = string
  default     = "coder"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.name))
    error_message = "name must be 2-15 chars, lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "centralus" # Postgres Flexible Server is restricted for this subscription in eastus2
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project    = "coder"
    managed-by = "terraform"
  }
}

# --- Networking ---------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the VNet."
  type        = string
  default     = "10.10.0.0/16"
}

variable "aks_subnet_prefix" {
  description = "Address prefix for the AKS node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "postgres_subnet_prefix" {
  description = "Address prefix for the subnet delegated to PostgreSQL Flexible Server."
  type        = string
  default     = "10.10.16.0/24"
}

# --- AKS ----------------------------------------------------------------------

variable "kubernetes_version" {
  description = "AKS Kubernetes version. null = latest default version for the region."
  type        = string
  default     = null
}

variable "aks_node_vm_size" {
  description = "VM size for the AKS node pool (runs system pods, coderd and workspaces)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "aks_node_min_count" {
  description = "Minimum node count for the node pool autoscaler."
  type        = number
  default     = 1
}

variable "aks_node_max_count" {
  description = "Maximum node count for the node pool autoscaler."
  type        = number
  default     = 3
}

variable "aks_admin_group_object_ids" {
  description = "Entra ID group object IDs granted cluster-admin via Azure RBAC."
  type        = list(string)
  default     = []
}

# --- PostgreSQL ---------------------------------------------------------------

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "postgres_sku_name" {
  description = "PostgreSQL Flexible Server SKU. Burstable is fine for small installs; use GP_Standard_D2ds_v5+ for production."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "PostgreSQL storage size in MB."
  type        = number
  default     = 32768
}

variable "postgres_backup_retention_days" {
  description = "Backup retention in days (7-35)."
  type        = number
  default     = 7
}

variable "postgres_admin_username" {
  description = "PostgreSQL administrator login."
  type        = string
  default     = "coderadmin"
}
