terraform {
  # Values are supplied at init time:
  #   terraform init -backend-config=platform.backend.hcl
  # Nothing here may contain secrets - authentication is OIDC + Entra RBAC on
  # the storage account (Storage Blob Data Contributor), never an access key.
  backend "azurerm" {}
}
