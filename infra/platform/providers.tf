terraform {
  # Write-only attributes, used for the GitHub PAT, require 1.11 or later.
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.14.0, < 5.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0.0, < 4.0.0"
    }
    fabric = {
      source  = "microsoft/fabric"
      version = ">= 1.2.0, < 2.0.0"
    }
  }
}

provider "fabric" {
  tenant_id = var.tenant_id
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Credentials come from the environment:
  #   ARM_USE_OIDC=true, ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
  # locally, `az login` is used instead.
  storage_use_azuread = true

  features {
    resource_group {
      # Refuse to silently delete a resource group that still holds resources.
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}
