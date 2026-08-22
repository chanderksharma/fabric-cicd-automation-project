#!/usr/bin/env bash
#
# Destroys everything one lane created. Irreversible.
#
# Bash equivalent of scripts/Remove-Platform.ps1. Order matters:
#
#   1. Fabric workspaces  (prod, test, dev)
#   2. Platform           (deployment pipeline, connection, capacity, RBAC, RG)
#   3. Orphan sweep       (anything named for this lane that Terraform lost)
#   4. App registration   (gh lane only)
#   5. Items repo branches
#   6. Entra groups       (shared; opt in)
#   7. Terraform state    (shared; opt in, and last, because Terraform needs it
#                          to know what to destroy)
#
# Only resources carrying this lane's suffix are touched.
#
set -uo pipefail

LANE="ml"
LEGACY="no"
NAME_PREFIX_OVERRIDE=""
WORKSPACE_PREFIX=""
PREFIX="contoso-fab"
APP_NAME=""
STATE_RG="rg-terraform-state"
STATE_LOCK="terraform-state-protect"
CONTAINER_PREFIX="tfstate"
ITEMS_REPO=""
ITEMS_REMOTE="origin"
ADMIN_GROUP="sg-fabric-platform-admins"
ENGINEER_GROUP="sg-fabric-data-engineers"
ANALYST_GROUP="sg-fabric-analysts"
FABRIC_API="https://api.fabric.microsoft.com"

CONFIRM="no"
ORPHANS_ONLY="no"
INCLUDE_BRANCHES="no"
INCLUDE_GROUPS="no"
INCLUDE_STATE="no"
KEEP_SP="no"

usage() {
  cat <<'EOF'
Usage: ./scripts/teardown.sh --confirm [options]

  --lane gh|ml           Lane to destroy (default: ml)
  --workspace-prefix P   Names the estate, replacing <prefix>-<lane>. Must match
                         what it was built with, or nothing is found
  --legacy               Target the pre-lane estate: names, state keys and app
                         registration without a lane suffix. The resulting
                         prefix also matches both lanes.
  --name-prefix NAME     Override the derived prefix outright
  --prefix NAME          Naming prefix (default: contoso-fab)
  --app-name NAME        Override sp-fabric-cicd-<lane>
  --items-repo PATH      Path to the items repository clone
  --orphans-only         Skip Terraform; delete by name instead
  --include-branches     Delete <lane>-dev/test/prod in the items repository
  --include-groups       Delete the SHARED Entra security groups
  --include-state        Delete the SHARED Terraform state resource group
  --keep-service-principal
  --confirm              Required. Without it, nothing happens.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)                    LANE="$2"; shift 2 ;;
    --legacy)                  LEGACY="yes"; shift ;;
    --name-prefix)             NAME_PREFIX_OVERRIDE="$2"; shift 2 ;;
    --workspace-prefix)        WORKSPACE_PREFIX="$2"; shift 2 ;;
    --prefix)                  PREFIX="$2"; shift 2 ;;
    --app-name)                APP_NAME="$2"; shift 2 ;;
    --items-repo)              ITEMS_REPO="$2"; shift 2 ;;
    --state-rg)                STATE_RG="$2"; shift 2 ;;
    --orphans-only)            ORPHANS_ONLY="yes"; shift ;;
    --include-branches)        INCLUDE_BRANCHES="yes"; shift ;;
    --include-groups)          INCLUDE_GROUPS="yes"; shift ;;
    --include-state)           INCLUDE_STATE="yes"; shift ;;
    --keep-service-principal)  KEEP_SP="yes"; shift ;;
    --confirm)                 CONFIRM="yes"; shift ;;
    -h|--help)                 usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$LANE" != "gh" && "$LANE" != "ml" ]]; then
  echo "--lane must be gh or ml" >&2
  exit 1
fi

# The lane suffix appears in three places that must agree: resource names, the
# state container and the app registration. --legacy drops it from all three.
# --workspace-prefix replaces the name and branch stems but not the container or
# the app registration, which stay lane-scoped.
if [[ -n "$WORKSPACE_PREFIX" ]]; then
  if [[ ! "$WORKSPACE_PREFIX" =~ ^[a-z][a-z0-9-]{2,30}$ ]]; then
    echo "--workspace-prefix must be 3-31 lowercase characters starting with a letter" >&2
    exit 1
  fi
fi

if [[ "$LEGACY" == "yes" ]]; then
  STATE_CONTAINER="$CONTAINER_PREFIX"
  BRANCH_PREFIX=""
  NAME_PREFIX="${NAME_PREFIX_OVERRIDE:-$PREFIX}"
  [[ -n "$APP_NAME" ]] || APP_NAME="sp-fabric-cicd"
else
  STATE_CONTAINER="${CONTAINER_PREFIX}-${LANE}"
  BRANCH_PREFIX="${LANE}-"
  NAME_PREFIX="${NAME_PREFIX_OVERRIDE:-${PREFIX}-${LANE}}"
  [[ -n "$APP_NAME" ]] || APP_NAME="sp-fabric-cicd-${LANE}"
fi

if [[ -n "$WORKSPACE_PREFIX" ]]; then
  BRANCH_PREFIX="${WORKSPACE_PREFIX}-"
  NAME_PREFIX="${NAME_PREFIX_OVERRIDE:-$WORKSPACE_PREFIX}"
fi

# Empty describes the estate that predates lanes, which is what lets destroy
# still reach it.
if [[ "$LEGACY" == "yes" ]]; then TF_LANE=""; else TF_LANE="$LANE"; fi

FABRIC_RG="rg-${NAME_PREFIX}-fabric"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "$ITEMS_REPO" ]] || ITEMS_REPO="$(dirname "$REPO_ROOT")/fabric-workspace-items"

if [[ "$CONFIRM" != "yes" ]]; then
  cat <<EOF
This destroys the '${LANE}' lane: every Fabric workspace named ${NAME_PREFIX}-*,
all item content inside them, and the Fabric capacity. OneLake data is deleted
with the workspace and is NOT recoverable.

Re-run with --confirm to proceed.
EOF
  usage
  exit 1
fi

FAILED=0
note_failure() { echo "    FAILED  $*" >&2; FAILED=1; }

# -----------------------------------------------------------------------------
# 1. Terraform destroy
# -----------------------------------------------------------------------------
terraform_destroy() {
  local dir="$1" backend="$2" key="$3" varfile="${4:-}" label="$5"
  shift 5
  local overrides=("$@")

  if ! terraform -chdir="${REPO_ROOT}/${dir}" init -reconfigure -no-color \
        -backend-config="$backend" \
        -backend-config="container_name=${STATE_CONTAINER}" \
        -backend-config="key=${key}"; then
    note_failure "init for ${label}: state may be unreachable behind the perimeter"
    return 1
  fi

  # Terraform must derive the same names the estate was built with, or the
  # capacity lookup misses and the plan fails before removing anything.
  local args=(destroy -auto-approve -no-color "-var=lane=${TF_LANE}" "-var=workspace_prefix=${WORKSPACE_PREFIX}")
  [[ -n "$varfile" ]] && args+=("-var-file=${varfile}")
  [[ ${#overrides[@]} -gt 0 ]] && args+=("${overrides[@]}")

  if ! terraform -chdir="${REPO_ROOT}/${dir}" "${args[@]}"; then
    note_failure "destroy for ${label}: the orphan sweep will try to finish the job"
    return 1
  fi
  echo "    destroyed ${label}"
}

# Fabric refuses to delete a workspace that is assigned to a deployment pipeline
# stage, so the pipeline has to go first. Terraform would do the opposite: the
# pipeline lives in the platform root, which is destroyed after the workspaces.
remove_deployment_pipelines() {
  local json found=0
  json="$(az rest --method GET --url "${FABRIC_API}/v1/deploymentPipelines" \
            --resource "$FABRIC_API" -o json 2>/dev/null || true)"
  if [[ -z "$json" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "    could not list deployment pipelines (no jq, insufficient permission, or none exist)"
    return
  fi

  while read -r id name; do
    [[ -n "$id" ]] || continue
    found=1
    if az rest --method DELETE --url "${FABRIC_API}/v1/deploymentPipelines/${id}" \
         --resource "$FABRIC_API" -o none 2>/dev/null; then
      echo "    deleted '${name}'"
    else
      note_failure "deployment pipeline '${name}': workspaces assigned to it cannot be deleted until it is gone"
    fi
  done < <(echo "$json" | jq -r --arg p "${NAME_PREFIX}-" \
             '.value[]? | select(.displayName != null) | select(.displayName | startswith($p)) | "\(.id) \(.displayName)"')

  [[ $found -eq 1 ]] || echo "    none found"
}

echo "==> Deleting deployment pipelines (they block workspace deletion)"
remove_deployment_pipelines

if [[ "$ORPHANS_ONLY" == "yes" ]]; then
  echo "==> Skipping Terraform (--orphans-only): deleting by name instead"
else
  # A suspended capacity refuses workspace operations, so leaving it paused
  # makes the workspace destroy fail rather than skip.
  echo "==> Resuming the capacity if it is paused"
  while read -r cap_id cap_name; do
    [[ -n "$cap_id" ]] || continue
    state="$(az resource show --ids "$cap_id" --query 'properties.state' -o tsv 2>/dev/null || true)"
    if [[ "$state" == "Paused" ]]; then
      az fabric capacity resume --resource-group "$FABRIC_RG" --capacity-name "$cap_name" -o none 2>/dev/null \
        && echo "    resumed ${cap_name}" \
        || echo "    could not resume ${cap_name}; workspace deletes may fail"
    else
      echo "    ${cap_name} is ${state:-absent}"
    fi
  done < <(az resource list --resource-group "$FABRIC_RG" \
             --resource-type Microsoft.Fabric/capacities \
             --query '[].[id,name]' -o tsv 2>/dev/null || true)

  echo "==> Destroying Fabric workspaces (prod, test, dev)"
  for env in prod test dev; do
    echo "--- ${env}"
    terraform_destroy "infra/workspace" "envs/${env}.backend.hcl" \
      "workspace-${env}.tfstate" "envs/${env}.tfvars" "${NAME_PREFIX}-${env}"
  done

  echo "==> Destroying the platform (capacity, pipeline, connection, RBAC)"
  # The stage workspaces are gone, so the pipeline's lookups would fail on read.
  # Disabling the gate still destroys the pipeline recorded in state.
  terraform_destroy "infra/platform" "platform.backend.hcl" \
    "platform.tfstate" "" "${NAME_PREFIX} platform" "-var=create_deployment_pipeline=false"
fi

# -----------------------------------------------------------------------------
# 2. Orphan sweep
# -----------------------------------------------------------------------------
# terraform destroy only removes what state records. Anything deleted out of
# band, created before a failed apply, or lost with a discarded state file stays
# behind and silently blocks the next build. Matching on the lane-suffixed name
# is the only safe way to tell one lane's leftovers from the other's.
echo "==> Sweeping for anything still named for this lane"

sweep_fabric() {
  local collection="$1" kind="$2" json
  json="$(az rest --method GET --url "${FABRIC_API}/v1/${collection}" \
            --resource "$FABRIC_API" -o json 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    echo "    could not list ${kind} (insufficient permission, or none exist)"
    return
  fi

  local found=0
  while read -r id name; do
    [[ -n "$id" ]] || continue
    found=1
    if az rest --method DELETE --url "${FABRIC_API}/v1/${collection}/${id}" \
         --resource "$FABRIC_API" -o none 2>/dev/null; then
      echo "    deleted ${kind} '${name}'"
    else
      note_failure "${kind} '${name}': delete rejected; you may not be an admin of it"
    fi
  done < <(echo "$json" | jq -r --arg p "${NAME_PREFIX}-" \
             '.value[]? | select(.displayName != null) | select(.displayName | startswith($p)) | "\(.id) \(.displayName)"')

  [[ $found -eq 1 ]] || echo "    no orphaned ${kind}"
}

if command -v jq >/dev/null 2>&1; then
  sweep_fabric "deploymentPipelines" "deployment pipeline"
  sweep_fabric "workspaces" "workspace"
  sweep_fabric "connections" "connection"
else
  echo "    jq not installed; skipping the Fabric orphan sweep" >&2
fi

# The resource group holds the capacity, so removing it catches a capacity that
# outlived its state file.
if az group show --name "$FABRIC_RG" -o none 2>/dev/null; then
  if az group delete --name "$FABRIC_RG" --yes -o none; then
    echo "    deleted resource group ${FABRIC_RG}"
  else
    note_failure "resource group ${FABRIC_RG}: check for a resource lock"
  fi
else
  echo "    resource group ${FABRIC_RG} already gone"
fi

# -----------------------------------------------------------------------------
# 3. App registration
# -----------------------------------------------------------------------------
echo "==> Removing the app registration '${APP_NAME}'"
if [[ "$KEEP_SP" == "yes" ]]; then
  echo "    kept (--keep-service-principal)"
else
  APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
  if [[ -z "$APP_ID" ]]; then
    echo "    '${APP_NAME}' not found"
  # Deleting the app removes its federated credentials and service principal
  # with it.
  elif az ad app delete --id "$APP_ID" -o none; then
    echo "    deleted '${APP_NAME}' (${APP_ID})"
  else
    note_failure "app registration ${APP_NAME}: you may not own it"
  fi
fi

# -----------------------------------------------------------------------------
# 4. Items repository branches
# -----------------------------------------------------------------------------
if [[ "$INCLUDE_BRANCHES" == "yes" ]]; then
  echo "==> Deleting this lane's branches in the items repository"
  if [[ ! -d "${ITEMS_REPO}/.git" ]]; then
    echo "    no git repository at ${ITEMS_REPO}; skipping"
  else
    for env in dev test prod; do
      branch="${BRANCH_PREFIX}${env}"
      if git -C "$ITEMS_REPO" push "$ITEMS_REMOTE" --delete "$branch" >/dev/null 2>&1; then
        echo "    deleted remote branch ${branch}"
      else
        echo "    (${branch} not on ${ITEMS_REMOTE})"
      fi
      git -C "$ITEMS_REPO" branch -D "$branch" >/dev/null 2>&1 || true
    done
  fi
fi

# -----------------------------------------------------------------------------
# 5. Entra groups (shared)
# -----------------------------------------------------------------------------
if [[ "$INCLUDE_GROUPS" == "yes" ]]; then
  echo "==> Deleting the shared Entra security groups"
  echo "    these are shared with the other lane; make sure it is gone"
  for group in "$ADMIN_GROUP" "$ENGINEER_GROUP" "$ANALYST_GROUP"; do
    OID="$(az ad group list --display-name "$group" --query '[0].id' -o tsv 2>/dev/null || true)"
    if [[ -z "$OID" ]]; then
      echo "    '${group}' not found"
    elif az ad group delete --group "$OID" -o none; then
      echo "    deleted '${group}'"
    else
      note_failure "entra group ${group}"
    fi
  done
fi

# -----------------------------------------------------------------------------
# 6. Terraform state (shared, last)
# -----------------------------------------------------------------------------
echo "==> Terraform state"
if [[ "$INCLUDE_STATE" != "yes" ]]; then
  echo "    kept. Re-run with --include-state to delete ${STATE_RG}."
elif ! az group show --name "$STATE_RG" -o none 2>/dev/null; then
  echo "    ${STATE_RG} already gone"
else
  # The CanNotDelete lock from bootstrap blocks the group delete, and also
  # blocks deleting perimeter rules, so it has to go first.
  az lock delete --name "$STATE_LOCK" --resource-group "$STATE_RG" -o none 2>/dev/null \
    && echo "    removed lock '${STATE_LOCK}'" \
    || echo "    (no lock found)"

  if az group delete --name "$STATE_RG" --yes --no-wait -o none; then
    echo "    deletion of ${STATE_RG} started (async)"
  else
    note_failure "resource group ${STATE_RG}: check for remaining locks"
  fi
fi

cat <<EOF

=============================================================================
Not removed by any script:
  - Fabric tenant settings (Git integration, service principal API access)
  - GitHub Environments and repository variables
  - The network security perimeter, unless --include-state was used
  - The other lane
=============================================================================
EOF

exit $FAILED
