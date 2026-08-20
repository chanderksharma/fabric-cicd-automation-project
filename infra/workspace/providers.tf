terraform {
  required_version = ">= 1.9.0"

  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = ">= 1.2.0, < 2.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}

provider "fabric" {
  tenant_id = var.tenant_id

  # Credentials are resolved from the environment so the same configuration
  # works locally and in CI:
  #   CI    : FABRIC_USE_OIDC=true, FABRIC_CLIENT_ID, FABRIC_TENANT_ID
  #           (the provider exchanges the GitHub Actions id-token itself)
  #   local : FABRIC_USE_CLI=true after `az login`
  # No client secret is ever configured.
}

provider "azuread" {
  tenant_id = var.tenant_id
}
