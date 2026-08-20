resource_group_name  = "rg-terraform-state"
storage_account_name = "stcontosofabtfstate"
container_name       = "tfstate-ml"

# The lane lives in the container, not the key. A later -backend-config wins, so
# the workflows override this with container_name=tfstate-gh rather than keeping
# a parallel set of files. A bare init therefore lands on the same lane as the
# default of var.lane, which is deliberate.
key = "platform.tfstate"

# Entra-based auth only. No account keys, no SAS tokens.
#
# use_oidc is deliberately NOT set here. CI supplies it through ARM_USE_OIDC,
# and a local run authenticates with `az login`. Hardcoding it would break
# local init, which has no OIDC token to exchange.
use_azuread_auth = true
