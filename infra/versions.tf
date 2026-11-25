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
