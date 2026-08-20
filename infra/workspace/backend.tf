terraform {
  # Values are supplied at init time, one file per environment:
  #   terraform init -backend-config=envs/dev.backend.hcl
  # Each environment therefore has its own state file and can be granted its own
  # blob-level RBAC scope.
  backend "azurerm" {}
}
