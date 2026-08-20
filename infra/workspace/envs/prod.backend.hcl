resource_group_name  = "rg-terraform-state"
storage_account_name = "stcontosofabtfstate"
container_name       = "tfstate-ml"

# ml lane. The workflows override with container_name=tfstate-gh.
key = "workspace-prod.tfstate"

# use_oidc comes from ARM_USE_OIDC in CI; local runs use `az login`.
use_azuread_auth = true
