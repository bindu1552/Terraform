terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.76.0"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
  features {}
  storage_use_azuread = true

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
