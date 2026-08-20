#!/usr/bin/env bash
#
# One-time bootstrap for the Fabric platform foundation.
#
# Creates everything Terraform cannot create for itself:
#   1. Resource group + storage account + container for remote state
#   2. The CI/CD app registration and its service principal
#   3. Six federated credentials (no client secret is ever created)
#   4. Azure RBAC for the service principal
#
# Run once, by a human with Owner on the subscription and permission to create
# app registrations in Entra ID. Safe to re-run: every step is idempotent.
#
# Usage:
#   ./scripts/bootstrap.sh --github-org chanderksharma \
#                          --github-org-id 293792156 \
#                          --github-repo fabric-cicd-automation-project \
#                          --github-repo-id 1340759336
#
set -euo pipefail

SUBSCRIPTION_ID=""
LOCATION="centralus"
PREFIX="contoso-fab"
STATE_RG="rg-terraform-state"
STATE_SA="stcontosofabtfstate"
STATE_CONTAINER="tfstate"
APP_NAME="sp-fabric-cicd"
ADMIN_GROUP="sg-fabric-platform-admins"
ENGINEER_GROUP="sg-fabric-data-engineers"
ANALYST_GROUP="sg-fabric-analysts"
NSP_NAME="sec-perimeter"
# Empty means "use the state resource group", so the perimeter is owned and torn
# down with the thing it protects rather than living in shared infrastructure.
NSP_RG=""
NSP_PROFILE="defaultProfile"
NSP_ACCESS_MODE="Enforced"
NSP_ALLOWED_IPS=""
# Outbound destinations permitted for resources inside the perimeter. Only
# relevant once a resource type that initiates outbound calls joins; a storage
# account does not.
NSP_ALLOWED_FQDNS="app.powerbi.com,api.fabric.microsoft.com,onelake.dfs.fabric.microsoft.com"
NSP_NO_AUTO_IP="no"
SKIP_NSP="no"
CREATE_GROUPS="no"
GITHUB_ORG=""
GITHUB_ORG_ID=""
GITHUB_REPO=""
GITHUB_REPO_ID=""
DEFAULT_BRANCH="main"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --subscription-id ID    Target subscription (default: current az account)
  --location REGION       Azure region (default: centralus)
  --prefix NAME           Naming prefix (default: contoso-fab)
  --state-rg NAME         State resource group (default: rg-terraform-state)
  --state-sa NAME         State storage account (default: stcontosofabtfstate)
  --state-container NAME  State container (default: tfstate)
  --app-name NAME         App registration display name (default: sp-fabric-cicd)
  --admin-group NAME      Entra group granted local state access
                          (default: sg-fabric-platform-admins)
  --create-groups         Create the three sg-fabric-* security groups if they
                          do not exist, and add you to the admin group. Omit
                          this when the groups are managed by identity
                          governance.
  --nsp-name NAME         Network security perimeter (default: sec-perimeter)
  --nsp-rg NAME           Perimeter resource group (default: the state
                          resource group)
  --nsp-profile NAME      Perimeter profile (default: defaultProfile)
  --nsp-access-mode MODE  Enforced or Learning (default: Enforced)
  --nsp-allowed-ips CIDRS Comma-separated extra inbound CIDRs
  --nsp-allowed-fqdns FQDNS Comma-separated outbound FQDNs
  --nsp-no-auto-ip        Do not add this machine's public IP inbound
  --skip-nsp              Do not create or associate a perimeter
  --github-org ORG        GitHub organisation (required)
  --github-org-id ID      Immutable GitHub organisation/user ID (required)
  --github-repo REPO      GitHub repository (required)
  --github-repo-id ID     Immutable GitHub repository ID (required)
  --branch NAME           Default branch (default: main)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id)   SUBSCRIPTION_ID="$2"; shift 2 ;;
    --location)          LOCATION="$2"; shift 2 ;;
    --prefix)            PREFIX="$2"; shift 2 ;;
    --state-rg)          STATE_RG="$2"; shift 2 ;;
    --state-sa)          STATE_SA="$2"; shift 2 ;;
    --state-container)   STATE_CONTAINER="$2"; shift 2 ;;
    --app-name)          APP_NAME="$2"; shift 2 ;;
    --admin-group)       ADMIN_GROUP="$2"; shift 2 ;;
    --create-groups)     CREATE_GROUPS="yes"; shift ;;
    --nsp-name)          NSP_NAME="$2"; shift 2 ;;
    --nsp-rg)            NSP_RG="$2"; shift 2 ;;
    --nsp-profile)       NSP_PROFILE="$2"; shift 2 ;;
    --nsp-access-mode)   NSP_ACCESS_MODE="$2"; shift 2 ;;
    --nsp-allowed-ips)   NSP_ALLOWED_IPS="$2"; shift 2 ;;
    --nsp-allowed-fqdns) NSP_ALLOWED_FQDNS="$2"; shift 2 ;;
    --nsp-no-auto-ip)    NSP_NO_AUTO_IP="yes"; shift ;;
    --skip-nsp)          SKIP_NSP="yes"; shift ;;
    --github-org)        GITHUB_ORG="$2"; shift 2 ;;
    --github-org-id)     GITHUB_ORG_ID="$2"; shift 2 ;;
    --github-repo)       GITHUB_REPO="$2"; shift 2 ;;
    --github-repo-id)    GITHUB_REPO_ID="$2"; shift 2 ;;
    --branch)            DEFAULT_BRANCH="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$GITHUB_ORG" || -z "$GITHUB_ORG_ID" || -z "$GITHUB_REPO" || -z "$GITHUB_REPO_ID" ]]; then
  echo "ERROR: --github-org, --github-org-id, --github-repo and --github-repo-id are required." >&2
  exit 1
fi

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
fi
az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID="$(az account show --query tenantId -o tsv)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKEND_FILES=(
  "infra/platform/platform.backend.hcl"
  "infra/workspace/envs/dev.backend.hcl"
  "infra/workspace/envs/test.backend.hcl"
  "infra/workspace/envs/prod.backend.hcl"
)

# Storage account names are globally unique, so --state-sa almost always has to
# be overridden. The four committed backend configs do not follow automatically.
check_backend_configs() {
  local mismatch=0 f
  for f in "${BACKEND_FILES[@]}"; do
    [[ -f "${REPO_ROOT}/${f}" ]] || continue
    if ! grep -Eq "^storage_account_name[[:space:]]*=[[:space:]]*\"${STATE_SA}\"" "${REPO_ROOT}/${f}"; then
      echo "    MISMATCH  ${f}"
      mismatch=1
    fi
    if ! grep -Eq "^resource_group_name[[:space:]]*=[[:space:]]*\"${STATE_RG}\"" "${REPO_ROOT}/${f}"; then
      echo "    MISMATCH  ${f} (resource group)"
      mismatch=1
    fi
  done
  return $mismatch
}

echo "==> Subscription : $SUBSCRIPTION_ID"
echo "==> Tenant       : $TENANT_ID"
echo "==> Repository   : $GITHUB_ORG/$GITHUB_REPO"

# -----------------------------------------------------------------------------
# 0. Entra security groups
#
# Terraform reads these with azuread_group data sources and never creates them,
# so that membership stays under identity governance. --create-groups exists for
# sandbox tenants where no such process is in place yet.
# -----------------------------------------------------------------------------
ensure_group() {
  local name="$1" oid
  oid="$(az ad group list --display-name "$name" --query '[0].id' -o tsv 2>/dev/null || true)"
  if [[ -n "$oid" ]]; then
    echo "    exists   $name  ($oid)"
    return 0
  fi
  if [[ "$CREATE_GROUPS" != "yes" ]]; then
    echo "    MISSING  $name"
    return 1
  fi
  oid="$(az ad group create --display-name "$name" --mail-nickname "$name" --query id -o tsv)"
  echo "    created  $name  ($oid)"
}

echo "==> Checking Entra security groups"
GROUPS_OK=0
for g in "$ADMIN_GROUP" "$ENGINEER_GROUP" "$ANALYST_GROUP"; do
  ensure_group "$g" || GROUPS_OK=1
done

if [[ "$CREATE_GROUPS" == "yes" ]]; then
  # Terraform reads the capacity through the Fabric API, which requires the
  # caller to be a capacity administrator. Membership here is what grants it.
  SIGNED_IN_OID="$(az ad signed-in-user show --query id -o tsv)"
  ADMIN_OID="$(az ad group list --display-name "$ADMIN_GROUP" --query '[0].id' -o tsv)"
  az ad group member add --group "$ADMIN_OID" --member-id "$SIGNED_IN_OID" -o none 2>/dev/null \
    && echo "    added you to $ADMIN_GROUP" \
    || echo "    (you are already a member of $ADMIN_GROUP)"
elif [[ "$GROUPS_OK" -ne 0 ]]; then
  echo "    Terraform will fail on the azuread_group data sources until these"
  echo "    groups exist. Re-run with --create-groups, or create them out of band."
fi

# -----------------------------------------------------------------------------
# 1. Remote state
# -----------------------------------------------------------------------------
echo "==> Creating state resource group"
az group create --name "$STATE_RG" --location "$LOCATION" \
  --tags managed-by=bootstrap purpose=terraform-state -o none

echo "==> Creating state storage account"
# A storage account cannot change region in place. Catch the mismatch here
# rather than letting the create call fail with a generic conflict.
EXISTING_LOCATION="$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query location -o tsv 2>/dev/null || true)"
if [[ -n "$EXISTING_LOCATION" && "$EXISTING_LOCATION" != "$LOCATION" ]]; then
  cat >&2 <<EOF
ERROR: storage account '${STATE_SA}' already exists in '${EXISTING_LOCATION}',
but this run targets '${LOCATION}'. A storage account cannot be moved between
regions.

Either keep the existing region (--location ${EXISTING_LOCATION}), or delete the
account and its resource group first. Deleting requires removing the
'terraform-state-protect' lock, and destroys all Terraform state in it:

    az lock delete --name terraform-state-protect --resource-group ${STATE_RG}
    az group delete --name ${STATE_RG} --yes
EOF
  exit 1
fi

az storage account create \
  --name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --location "$LOCATION" \
  --sku Standard_ZRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --tags managed-by=bootstrap purpose=terraform-state \
  -o none

echo "==> Enabling blob versioning and soft delete (state recovery)"
az storage account blob-service-properties update \
  --account-name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 \
  --enable-container-delete-retention true \
  --container-delete-retention-days 30 \
  -o none

SA_ID="$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query id -o tsv)"

echo "==> Granting the current user Storage Blob Data Contributor (needed to create the container)"
CURRENT_USER_OID="$(az ad signed-in-user show --query id -o tsv)"
az role assignment create \
  --assignee-object-id "$CURRENT_USER_OID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID" -o none 2>/dev/null || echo "    (already assigned)"

# Without this, only the person who ran bootstrap can run Terraform locally.
echo "==> Granting '$ADMIN_GROUP' Storage Blob Data Contributor for local runs"
ADMIN_GROUP_OID="$(az ad group list --display-name "$ADMIN_GROUP" --query '[0].id' -o tsv 2>/dev/null || true)"
if [[ -n "$ADMIN_GROUP_OID" ]]; then
  az role assignment create \
    --assignee-object-id "$ADMIN_GROUP_OID" \
    --assignee-principal-type Group \
    --role "Storage Blob Data Contributor" \
    --scope "$SA_ID" -o none 2>/dev/null || echo "    (already assigned)"
else
  echo "    group '$ADMIN_GROUP' not found. Create it, then re-run this script"
  echo "    so other engineers can run Terraform locally against shared state."
fi

# Governance policy rewrites publicNetworkAccess to SecuredByPerimeter, so the
# account is unreachable until the perimeter association exists. Report the
# value for the record, but treat it as expected rather than a problem.
EFFECTIVE_ACCESS="$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query publicNetworkAccess -o tsv)"
echo "==> publicNetworkAccess is '${EFFECTIVE_ACCESS}'"

# -----------------------------------------------------------------------------
# 1b. Network security perimeter
#
# Must run BEFORE the container is created. Governance forces the account to
# SecuredByPerimeter, which means it is unreachable until it belongs to a
# perimeter - so the association is what makes the data plane usable, not an
# afterthought.
#
# The perimeter is created here rather than reusing a shared one, so access
# rules can be changed without touching infrastructure other teams depend on.
# -----------------------------------------------------------------------------
if [[ "$SKIP_NSP" == "yes" ]]; then
  echo "==> Skipping network security perimeter (--skip-nsp)"
else
  [[ -n "$NSP_RG" ]] || NSP_RG="$STATE_RG"

  NSP_API="2023-08-01-preview"
  NSP_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${NSP_RG}/providers/Microsoft.Network/networkSecurityPerimeters/${NSP_NAME}"
  NSP_URL="https://management.azure.com${NSP_ID}"

  # ARM PUT with the body in a file, to sidestep shell quoting differences.
  az_rest_put() {
    local url="$1" body="$2" tmp
    tmp="$(mktemp)"
    printf '%s' "$body" > "$tmp"
    az rest --method PUT --url "$url" --headers "Content-Type=application/json" --body "@${tmp}" -o none
    rm -f "$tmp"
  }

  echo "==> Creating network security perimeter '${NSP_NAME}' in ${NSP_RG}"
  az_rest_put "${NSP_URL}?api-version=${NSP_API}" \
    "{\"location\":\"${LOCATION}\",\"properties\":{},\"tags\":{\"managed-by\":\"bootstrap\",\"purpose\":\"terraform-state\"}}"

  echo "    creating profile '${NSP_PROFILE}'"
  az_rest_put "${NSP_URL}/profiles/${NSP_PROFILE}?api-version=${NSP_API}" '{"properties":{}}'

  # Inbound from any resource in this subscription. This is what lets a
  # self-hosted CI runner on Azure reach the state account.
  echo "    rule: inbound-subscription"
  az_rest_put "${NSP_URL}/profiles/${NSP_PROFILE}/accessRules/inbound-subscription?api-version=${NSP_API}" \
    "{\"properties\":{\"direction\":\"Inbound\",\"subscriptions\":[{\"id\":\"/subscriptions/${SUBSCRIPTION_ID}\"}]}}"

  ip_list="$NSP_ALLOWED_IPS"
  if [[ "$NSP_NO_AUTO_IP" != "yes" ]]; then
    my_ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$my_ip" ]]; then
      echo "    detected public IP ${my_ip}"
      ip_list="${ip_list:+${ip_list},}${my_ip}/32"
    else
      echo "WARNING: could not detect the public IP. Use --nsp-allowed-ips." >&2
    fi
  fi

  # One rule per prefix rather than a single rule holding all of them.
  # Rewriting an existing rule restarts perimeter propagation and locks out
  # whoever was already allowed, for several minutes.
  if [[ -n "$ip_list" ]]; then
    IFS=',' read -ra _prefixes <<<"$ip_list"
    for prefix in "${_prefixes[@]}"; do
      prefix="$(echo "$prefix" | tr -d '[:space:]')"
      [[ -n "$prefix" ]] || continue
      rule_name="inbound-ip-$(echo "$prefix" | tr './' '--')"
      echo "    rule: ${rule_name} (${prefix})"
      az_rest_put "${NSP_URL}/profiles/${NSP_PROFILE}/accessRules/${rule_name}?api-version=${NSP_API}" \
        "{\"properties\":{\"direction\":\"Inbound\",\"addressPrefixes\":[\"${prefix}\"]}}"
    done
  fi

  if [[ -n "$NSP_ALLOWED_FQDNS" ]]; then
    fqdns_json="$(python -c "import sys; print(','.join('\"%s\"' % p.strip() for p in sys.argv[1].split(',') if p.strip()))" "$NSP_ALLOWED_FQDNS")"
    echo "    rule: outbound-fqdn (${NSP_ALLOWED_FQDNS})"
    az_rest_put "${NSP_URL}/profiles/${NSP_PROFILE}/accessRules/outbound-fqdn?api-version=${NSP_API}" \
      "{\"properties\":{\"direction\":\"Outbound\",\"fullyQualifiedDomainNames\":[${fqdns_json}]}}"
  fi

  echo "==> Associating storage account with '${NSP_NAME}'"
  ASSOCIATION_NAME="assoc-${STATE_SA}"
  az_rest_put "${NSP_URL}/resourceAssociations/${ASSOCIATION_NAME}?api-version=${NSP_API}" \
    "{\"properties\":{\"privateLinkResource\":{\"id\":\"${SA_ID}\"},\"profile\":{\"id\":\"${NSP_ID}/profiles/${NSP_PROFILE}\"},\"accessMode\":\"${NSP_ACCESS_MODE}\"}}"
  echo "    associated as '${ASSOCIATION_NAME}' in ${NSP_ACCESS_MODE} mode"

  # Governance creates the account with publicNetworkAccess=Disabled, which
  # rejects all public traffic before perimeter rules are ever evaluated.
  # Associating a perimeter does not flip it, so set it explicitly - and only
  # now, because the value is rejected until an association exists.
  echo "    setting publicNetworkAccess to SecuredByPerimeter"
  az storage account update \
    --name "$STATE_SA" \
    --resource-group "$STATE_RG" \
    --public-network-access SecuredByPerimeter \
    -o none

  EFFECTIVE_ACCESS="$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query publicNetworkAccess -o tsv)"
  echo "    publicNetworkAccess is now '${EFFECTIVE_ACCESS}'"
  if [[ "$EFFECTIVE_ACCESS" != "SecuredByPerimeter" ]]; then
    echo "WARNING: expected 'SecuredByPerimeter' but got '${EFFECTIVE_ACCESS}'." >&2
    echo "    Policy is overriding the value and the account will stay unreachable." >&2
  fi
fi

# Three things are eventually consistent here: RBAC propagation to the storage
# data plane, the perimeter association, and the perimeter access rules. The
# last of those is the slowest, so allow several minutes.
echo "==> Creating state container"
created="no"
for attempt in $(seq 1 20); do
  if output="$(az storage container create --name "$STATE_CONTAINER" --account-name "$STATE_SA" --auth-mode login -o none 2>&1)"; then
    created="yes"
    echo "    created (attempt ${attempt})"
    break
  fi

  if grep -Eqi 'blocked by network rules|public network access|not authorized to perform this operation' <<<"$output"; then
    echo "    attempt ${attempt}/20: blocked by network or RBAC, retrying in 20s"
  else
    echo "az storage container create failed: ${output}" >&2
    exit 1
  fi
  sleep 20
done

if [[ "$created" != "yes" ]]; then
  cat >&2 <<EOF

ERROR: could not create container '${STATE_CONTAINER}' in '${STATE_SA}'.
publicNetworkAccess is '${EFFECTIVE_ACCESS}'.

The account is inside perimeter '${NSP_NAME}' but this client cannot reach it.
Add an inbound access rule to profile '${NSP_PROFILE}' covering your network,
run from inside the perimeter, or re-run with --nsp-access-mode Learning while
access rules are worked out.
EOF
  exit 1
fi

# Losing this storage account means losing the record of every deployed
# resource. Versioning and soft delete cover accidental blob overwrites; the
# lock covers accidental deletion of the account itself.
echo "==> Locking the state resource group against deletion"
az lock create \
  --name "terraform-state-protect" \
  --lock-type CanNotDelete \
  --resource-group "$STATE_RG" \
  --notes "Terraform state. Remove only during a deliberate teardown." \
  -o none 2>/dev/null || echo "    (lock already exists)"

# -----------------------------------------------------------------------------
# 2. App registration + service principal
# -----------------------------------------------------------------------------
echo "==> Creating app registration '$APP_NAME'"
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
fi

SP_OID="$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
if [[ -z "$SP_OID" ]]; then
  SP_OID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
fi

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
DIRECTORY_READ_ALL_ROLE_ID="7ab1d382-f21e-4acd-a863-ba3e13f7da61"
if [[ "$(az ad app permission list \
  --id "$APP_ID" \
  --query "[?resourceAppId=='${GRAPH_APP_ID}'].resourceAccess[] | [?id=='${DIRECTORY_READ_ALL_ROLE_ID}' && type=='Role'] | length(@)" \
  -o tsv)" != "1" ]]; then
  az ad app permission add \
    --id "$APP_ID" \
    --api "$GRAPH_APP_ID" \
    --api-permissions "${DIRECTORY_READ_ALL_ROLE_ID}=Role" \
    -o none
  echo "    added Microsoft Graph Directory.Read.All application permission"
fi

echo "    appId (client id)      : $APP_ID"
echo "    service principal oid  : $SP_OID"

# -----------------------------------------------------------------------------
# 3. Federated credentials - one per GitHub Environment plus one for PR plans.
#    No client secret is created, so there is nothing to rotate or leak.
# -----------------------------------------------------------------------------
add_federated_credential() {
  local name="$1" subject="$2" existing_subject output delay attempt
  existing_subject="$(az ad app federated-credential show \
    --id "$APP_ID" \
    --federated-credential-id "$name" \
    --query subject -o tsv 2>/dev/null || true)"
  if [[ "$existing_subject" == "$subject" ]]; then
    echo "    federated credential '$name' already matches"
    return 0
  fi
  if [[ -n "$existing_subject" ]]; then
    echo "    replacing drifted federated credential '$name'"
    az ad app federated-credential delete \
      --id "$APP_ID" \
      --federated-credential-id "$name"
  fi

  for attempt in $(seq 1 6); do
    if output="$(az ad app federated-credential create --id "$APP_ID" --parameters "$(cat <<JSON
{
  "name": "$name",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$subject",
  "description": "GitHub Actions OIDC for $subject",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
  )" -o none 2>&1)"; then
      echo "    added federated credential '$name' -> $subject"
      return 0
    fi

    existing_subject="$(az ad app federated-credential show \
      --id "$APP_ID" \
      --federated-credential-id "$name" \
      --query subject -o tsv 2>/dev/null || true)"
    if [[ "$existing_subject" == "$subject" ]]; then
      echo "    federated credential '$name' exists after a delayed response"
      return 0
    fi

    if [[ "$attempt" -eq 6 ]] || ! grep -Eqi 'already exists|duplicate values|conflict|concurrent requests|temporar|wait briefly' <<<"$output"; then
      echo "az ad app federated-credential create failed: $output" >&2
      return 1
    fi

    delay=$((5 * attempt))
    echo "    '$name' is waiting for Entra propagation; retrying in ${delay}s"
    sleep "$delay"
  done
}

echo "==> Adding federated credentials"
REPOSITORY_SUBJECT="${GITHUB_ORG}@${GITHUB_ORG_ID}/${GITHUB_REPO}@${GITHUB_REPO_ID}"
add_federated_credential "gh-env-platform" "repo:${REPOSITORY_SUBJECT}:environment:platform"
add_federated_credential "gh-env-dev"      "repo:${REPOSITORY_SUBJECT}:environment:dev"
add_federated_credential "gh-env-test"     "repo:${REPOSITORY_SUBJECT}:environment:test"
add_federated_credential "gh-env-prod"     "repo:${REPOSITORY_SUBJECT}:environment:prod"
add_federated_credential "gh-pull-request" "repo:${REPOSITORY_SUBJECT}:pull_request"
add_federated_credential "gh-branch-main"  "repo:${REPOSITORY_SUBJECT}:ref:refs/heads/${DEFAULT_BRANCH}"

# -----------------------------------------------------------------------------
# 4. Azure RBAC
# -----------------------------------------------------------------------------
assign_role() {
  local role="$1" scope="$2" existing output attempt delay
  existing="$(az role assignment list \
    --scope "$scope" \
    --query "[?principalId=='${SP_OID}' && roleDefinitionName=='${role}'].id | [0]" \
    -o tsv)"
  if [[ -n "$existing" ]]; then
    echo "    $role already assigned at $scope"
    return 0
  fi

  for attempt in $(seq 1 6); do
    if output="$(az role assignment create \
      --assignee-object-id "$SP_OID" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope "$scope" -o none 2>&1)"; then
      echo "    assigned $role at $scope"
      return 0
    fi

    if [[ "$attempt" -eq 6 ]] || ! grep -Eqi 'principal.*not found|does not exist|conflict|concurrent|temporar|try again' <<<"$output"; then
      echo "az role assignment create failed: $output" >&2
      return 1
    fi

    delay=$((10 * attempt))
    echo "    waiting for service principal propagation; retrying $role in ${delay}s"
    sleep "$delay"
  done
}

echo "==> Assigning Azure RBAC to the service principal"
# Read/write on the state blobs.
assign_role "Storage Blob Data Contributor" "$SA_ID"
# Contributor is required to create the Fabric capacity resource group.
# User Access Administrator is required because the platform root manages role
# assignments. Narrow both to a pre-created resource group if your governance
# model forbids subscription-scope grants.
assign_role "Contributor" "/subscriptions/$SUBSCRIPTION_ID"
assign_role "User Access Administrator" "/subscriptions/$SUBSCRIPTION_ID"

# -----------------------------------------------------------------------------
# 5. Consistency check
# -----------------------------------------------------------------------------
echo "==> Checking the committed backend configs point at this storage account"
if check_backend_configs; then
  echo "    all four backend configs match."
else
  cat <<EOF

    The files above still reference a different storage account or resource
    group. terraform init will fail until they are updated to:

      resource_group_name  = "$STATE_RG"
      storage_account_name = "$STATE_SA"

EOF
fi

# -----------------------------------------------------------------------------
# Next steps
# -----------------------------------------------------------------------------
cat <<EOF

=============================================================================
Bootstrap complete. None of the values below are secrets.

  AZURE_CLIENT_ID        $APP_ID
  AZURE_TENANT_ID        $TENANT_ID
  AZURE_SUBSCRIPTION_ID  $SUBSCRIPTION_ID
  SP object id           $SP_OID   <- cicd_service_principal_object_id

Remaining manual steps:

  1. Set the three values above as GitHub *repository* variables (for PR plans)
     and as *environment* variables on platform, dev, test and prod.

  2. Create the GitHub Environments: platform, dev, test, prod.
     Add required reviewers to test and prod.

  3. Put SP object id ($SP_OID) into:
       infra/platform/terraform.tfvars
       infra/workspace/envs/*.tfvars
     as cicd_service_principal_object_id.

  4. In the Fabric admin portal (Tenant settings), enable:
       - Service principals can use Fabric APIs
       - Service principals can access read-only admin APIs
       - Users can create Fabric items
       - Allow service principals to create workspaces, connections and
         deployment pipelines
     Scope each to a security group containing $APP_NAME.
     Terraform cannot set tenant settings; this step is a manual runbook.

  5. Create the Entra security groups referenced by the Terraform data sources:
       sg-fabric-platform-admins
       sg-fabric-data-engineers
       sg-fabric-analysts

  6. Apply in order:
       terraform -chdir=infra/platform init -backend-config=platform.backend.hcl
       terraform -chdir=infra/platform apply
     then let the terraform-apply workflow handle dev, test and prod.
=============================================================================
EOF
