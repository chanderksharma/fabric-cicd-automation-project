#!/usr/bin/env bash
#
# Adds the signed-in user to the Fabric security groups.
#
# Terraform grants workspace roles to groups and never to individuals, so a
# person gains access by joining one. Nobody sees a workspace until then,
# including whoever built the platform: bootstrap adds the identity it ran as,
# which in CI is a service principal rather than your account.
#
# Membership is checked before it is written, so re-running changes nothing.
#
# Fabric stores the group's object ID rather than its name. A group that was
# deleted and recreated is a new object, so this has to be repeated after a
# teardown and rebuild even though the names look unchanged.

set -euo pipefail

ADMIN_GROUP="sg-fabric-platform-admins"
ENGINEER_GROUP="sg-fabric-data-engineers"
ANALYST_GROUP="sg-fabric-analysts"
ALL="no"
DRY_RUN="no"

usage() {
  cat <<'EOF'
Usage: ./scripts/add-me-to-fabric-groups.sh [options]

Options:
  --all                  Join the engineer and analyst groups as well. Admin
                         alone is enough to administer every workspace
  --admin-group NAME     (default: sg-fabric-platform-admins)
  --engineer-group NAME  (default: sg-fabric-data-engineers)
  --analyst-group NAME   (default: sg-fabric-analysts)
  --dry-run              Report what would change and write nothing
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)             ALL="yes"; shift ;;
    --admin-group)     ADMIN_GROUP="$2"; shift 2 ;;
    --engineer-group)  ENGINEER_GROUP="$2"; shift 2 ;;
    --analyst-group)   ANALYST_GROUP="$2"; shift 2 ;;
    --dry-run)         DRY_RUN="yes"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

MEMBER_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [[ -z "$MEMBER_ID" ]]; then
  echo "ERROR: could not resolve the signed-in user. Run 'az login' first." >&2
  echo "       A service principal session cannot use this script: /me needs a delegated token." >&2
  exit 1
fi
UPN="$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || true)"
echo "Signed in as ${UPN} (${MEMBER_ID})"

if [[ "$ALL" == "yes" ]]; then
  TARGETS=("$ADMIN_GROUP" "$ENGINEER_GROUP" "$ANALYST_GROUP")
else
  TARGETS=("$ADMIN_GROUP")
fi

MISSING=0
for name in "${TARGETS[@]}"; do
  group_id="$(az ad group list --display-name "$name" --query "[0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$group_id" ]]; then
    echo "WARNING: group '${name}' does not exist. Create it with scripts/bootstrap.sh --create-groups" >&2
    MISSING=$((MISSING + 1))
    continue
  fi

  is_member="$(az ad group member check --group "$group_id" --member-id "$MEMBER_ID" --query value -o tsv 2>/dev/null || true)"
  if [[ "$is_member" == "true" ]]; then
    printf '  %-28s %s  already a member\n' "$name" "$group_id"
    continue
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '  %-28s %s  would add\n' "$name" "$group_id"
    continue
  fi

  if ! az ad group member add --group "$group_id" --member-id "$MEMBER_ID" -o none; then
    echo "ERROR: failed to add you to '${name}'" >&2
    exit 1
  fi
  printf '  %-28s %s  added\n' "$name" "$group_id"
done

if [[ "$MISSING" -eq "${#TARGETS[@]}" ]]; then
  echo "ERROR: none of the groups exist. Run scripts/bootstrap.sh --create-groups" >&2
  exit 1
fi

echo
echo "Fabric caches group membership, so allow a few minutes before the workspaces appear."
