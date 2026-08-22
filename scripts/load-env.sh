#!/usr/bin/env bash
#
# Loads .env into the current shell as TF_VAR_* and ARM_* variables, giving a
# local shell the same inputs the GitHub workflows receive.
#
# Must be sourced, not executed, or the variables vanish with the subshell:
#
#     source ./scripts/load-env.sh
#
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: source this script, do not execute it:" >&2
  echo "         source ./scripts/load-env.sh" >&2
  exit 1
fi

_env_file="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"

if [[ ! -f "$_env_file" ]]; then
  echo "ERROR: no .env found at $_env_file" >&2
  echo "       cp .env.example .env and fill it in." >&2
  return 1
fi

set -a
# shellcheck disable=SC1090
source "$_env_file"
set +a

for _key in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID FABRIC_CICD_SP_OBJECT_ID; do
  if [[ -z "${!_key:-}" ]]; then
    echo "ERROR: $_key is not set in $_env_file" >&2
    return 1
  fi
  if [[ "${!_key}" == "00000000-0000-0000-0000-000000000000" ]]; then
    echo "WARNING: $_key is still the placeholder GUID" >&2
  fi
done

# Terraform input variables. Same names the workflows pass.
export TF_VAR_tenant_id="$AZURE_TENANT_ID"
export TF_VAR_subscription_id="$AZURE_SUBSCRIPTION_ID"
export TF_VAR_cicd_service_principal_object_id="$FABRIC_CICD_SP_OBJECT_ID"

# Optional: only needed once Git integration is enabled.
if [[ -n "${FABRIC_GITHUB_CONNECTION_ID:-}" ]]; then
  export TF_VAR_github_connection_id="$FABRIC_GITHUB_CONNECTION_ID"
else
  unset TF_VAR_github_connection_id
fi

# Absent means names derive from prefix and lane. Unset rather than left empty,
# so a stale value from an earlier shell cannot rename the estate.
if [[ -n "${FABRIC_WORKSPACE_PREFIX:-}" ]]; then
  if [[ ! "$FABRIC_WORKSPACE_PREFIX" =~ ^[a-z][a-z0-9-]{2,30}$ ]]; then
    echo "ERROR: FABRIC_WORKSPACE_PREFIX must be 3-31 lowercase characters starting with a letter" >&2
    return 1
  fi
  export TF_VAR_workspace_prefix="$FABRIC_WORKSPACE_PREFIX"
else
  unset TF_VAR_workspace_prefix
fi

# Provider configuration. ARM_USE_OIDC is deliberately NOT set: locally the
# providers authenticate with the Azure CLI session.
export ARM_TENANT_ID="$AZURE_TENANT_ID"
export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"

echo "Loaded $_env_file"
echo "  TF_VAR_workspace_prefix                 = ${TF_VAR_workspace_prefix:-(unset; names derive from prefix and lane)}"
echo "  TF_VAR_tenant_id                        = $TF_VAR_tenant_id"
echo "  TF_VAR_subscription_id                  = $TF_VAR_subscription_id"
echo "  TF_VAR_cicd_service_principal_object_id = $TF_VAR_cicd_service_principal_object_id"

unset _env_file _key
