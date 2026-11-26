terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
  }

  # Partial backend config: storage account / container / key are supplied at
  # `terraform init` time via -backend-config (see .github/workflows/terraform.yml
  # and infra/README.md).
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # Resource providers are registered once by infra/bootstrap/bootstrap.sh, so
  # the CI principal doesn't need subscription-wide register permissions.
  resource_provider_registrations = "none"
}

# Talks to the AKS API server with an Entra ID token from kubelogin (local
# accounts are disabled). kubelogin reuses the `az login` session: in CI that's
# the azure/login step, locally it's your own `az login`.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.main.kube_config[0].host
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args = [
      "get-token",
      "--login", "azurecli",
      # Well-known application ID of the AKS Entra ID server.
      "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630",
    ]
  }
}
