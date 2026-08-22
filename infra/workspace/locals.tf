locals {
  name_prefix    = var.lane == "" ? var.prefix : "${var.prefix}-${var.lane}"
  workspace_name = "${local.name_prefix}-${var.environment}"

  # Matches the platform root's capacity naming, so the two state files agree
  # without passing a value between them.
  capacity_name = var.capacity_key == "" ? null : coalesce(
    var.capacity_display_name,
    "${local.name_prefix}-${var.capacity_key}"
  )

  # Least privilege per environment. Humans lose write access as changes move
  # towards prod; every prod change must therefore flow through CI/CD.
  #
  #   dev  : engineers author freely
  #   test : engineers can read to validate a promotion, nothing more
  #   prod : humans read only - break glass is the Fabric admin portal or a
  #          temporary role_overrides entry applied through a reviewed PR
  default_human_roles = {
    dev = {
      platform_admins = "Admin"
      data_engineers  = "Member"
      analysts        = "Viewer"
    }
    test = {
      platform_admins = "Admin"
      data_engineers  = "Viewer"
      analysts        = "Viewer"
    }
    prod = {
      platform_admins = "Viewer"
      data_engineers  = "Viewer"
      analysts        = "Viewer"
    }
  }

  human_roles = merge(local.default_human_roles[var.environment], var.role_overrides)

  # An unset GitHub Actions variable arrives as "", so a partially populated map
  # still falls back to looking the groups up by name.
  lookup_groups = length([
    for k in ["platform_admins", "data_engineers", "analysts"] : k
    if lookup(var.group_object_ids, k, "") != ""
  ]) < 3

  group_object_ids = local.lookup_groups ? {
    platform_admins = data.azuread_group.platform_admins[0].object_id
    data_engineers  = data.azuread_group.data_engineers[0].object_id
    analysts        = data.azuread_group.analysts[0].object_id
  } : var.group_object_ids

  # Fabric automatically grants the workspace creator Admin. Managing that
  # same principal again returns PrincipalAlreadyHasWorkspaceRolePermissions.
  # Terraform manages the durable group assignments instead.
  role_assignments = {
    for group_key, role in local.human_roles : group_key => {
      principal_id   = local.group_object_ids[group_key]
      principal_type = "Group"
      role           = role
    }
  }

  description = coalesce(
    var.workspace_description,
    "${upper(var.environment)} workspace for ${local.name_prefix}. Infrastructure by Terraform, item content by Git integration. Do not edit items in the portal outside dev."
  )

  # The connection is created once in the platform root. Its GUID arrives as
  # TF_VAR_github_connection_id rather than through a data source: the
  # fabric_connections data source enumerates every connection in the tenant and
  # fails outright if any one of them uses a connectivity type the provider does
  # not recognise.
  git_defaults = {
    provider_type           = var.git_provider_type
    owner_name              = var.git_owner_name
    organization_name       = null
    project_name            = null
    repository_name         = var.git_repository_name
    branch_name             = coalesce(var.git_branch_name, var.lane == "" ? var.environment : "${var.lane}-${var.environment}")
    directory_name          = var.git_directory_name
    connection_id           = var.github_connection_id
    credentials_source      = "ConfiguredConnection"
    initialization_strategy = var.git_initialization_strategy
    allow_override_items    = var.git_allow_override_items
  }

  # Only the keys the caller actually set win; an omitted optional attribute
  # arrives as null and must not blank out the derived value.
  git_overrides = var.git_integration == null ? {} : {
    for k, v in var.git_integration : k => v if v != null
  }

  git_desired = merge(local.git_defaults, local.git_overrides)

  # GitHub integration is impossible without a connection, and the connection is
  # created later in the platform root than the workspace needs it. Rather than
  # failing the first apply, the workspace is built unconnected and picks up Git
  # on the next run once TF_VAR_github_connection_id is set. The
  # git_integration_enabled output makes that state visible.
  git_enabled     = var.enable_git_integration && local.git_desired.connection_id != null
  git_integration = local.git_enabled ? local.git_desired : null
}
