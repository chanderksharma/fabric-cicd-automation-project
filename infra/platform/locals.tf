locals {
  # Reading the directory is the only thing the deployment identity needs a
  # Microsoft Graph permission for. Supplying the group object ID removes it.
  # An unset GitHub Actions variable arrives as "", not null. coalesce cannot
  # do this test: it errors when every argument is null or empty.
  lookup_directory = var.platform_admin_group_object_id == null || var.platform_admin_group_object_id == ""

  platform_admin_group_object_id = local.lookup_directory ? data.azuread_group.platform_admins[0].object_id : var.platform_admin_group_object_id

  caller_user_principal_names = local.lookup_directory ? data.azuread_users.caller[0].user_principal_names : []

  # Single source of naming truth. Everything a lane owns hangs off this, so
  # the gh and ml builds never contend for the same Azure or Fabric object.
  # An empty lane reproduces the pre-lane names, which is what lets destroy
  # reach that estate. workspace_prefix replaces the whole stem when set.
  # An unset GitHub Actions variable arrives as "", not null.
  explicit_prefix     = var.workspace_prefix != null && var.workspace_prefix != ""
  derived_name_prefix = var.lane == "" ? var.prefix : "${var.prefix}-${var.lane}"
  name_prefix         = local.explicit_prefix ? var.workspace_prefix : local.derived_name_prefix

  tenant_id       = coalesce(var.tenant_id, data.azurerm_client_config.current.tenant_id)
  subscription_id = coalesce(var.subscription_id, data.azurerm_client_config.current.subscription_id)

  github_connection_name = coalesce(var.github_connection_name, "${local.name_prefix}-items")

  # Falls back to the caller, which is the ml lane's whole model: no CI
  # principal exists, so the operator holds the standing access.
  admin_principal_id = coalesce(
    var.cicd_service_principal_object_id,
    data.azuread_client_config.current.object_id,
  )

  admin_principal_type = var.cicd_service_principal_object_id != null ? "ServicePrincipal" : (
    length(local.caller_user_principal_names) > 0 ? "User" : "ServicePrincipal"
  )

  base_tags = merge(var.tags, {
    "managed-by" = "terraform"
    "lane"       = var.lane
    "repo"       = "chandsharma_microsoft/fabric-cicd-automation-project"
  })

  # Every capacity is administered by the CI/CD SPN and the members of the
  # platform admin group. Without the SPN here the fabric_capacity data source
  # in the workspace root returns 401 and workspace-to-capacity assignment
  # fails.
  #
  # Groups cannot be used directly: the capacity API accepts only users and
  # service principals, so the group is expanded to UPNs. A user caller is added
  # by UPN rather than object ID for the same reason.
  common_capacity_admins = concat(
    var.cicd_service_principal_object_id == null ? [] : [var.cicd_service_principal_object_id],
    local.caller_user_principal_names,
    local.lookup_directory ? data.azuread_users.platform_admins[0].user_principal_names : [],
    var.platform_admin_upns,
  )

  capacities = {
    for key, cap in var.capacities : key => {
      name     = "${local.name_prefix}-${key}"
      sku      = cap.sku
      location = coalesce(cap.location, var.location)
      admins = distinct(concat(
        local.common_capacity_admins,
        cap.additional_admin_object_ids,
        cap.additional_admin_upns,
      ))
    }
  }

  # Azure-plane RBAC. Humans get read-only on the capacity resource group;
  # all mutation flows through the CI/CD principal.
  azure_role_assignments = merge(
    {
      cicd_contributor = {
        scope                = azurerm_resource_group.fabric.id
        role_definition_name = "Contributor"
        principal_id         = local.admin_principal_id
        principal_type       = local.admin_principal_type
        description          = "Manages the Fabric capacity lifecycle in the ${var.lane} lane."
      }
      cicd_rbac_admin = {
        scope                = azurerm_resource_group.fabric.id
        role_definition_name = "User Access Administrator"
        principal_id         = local.admin_principal_id
        principal_type       = local.admin_principal_type
        description          = "Required so Terraform can manage role assignments inside this resource group."
      }
      platform_admins_owner = {
        scope                = azurerm_resource_group.fabric.id
        role_definition_name = "Reader"
        principal_id         = local.platform_admin_group_object_id
        principal_type       = "Group"
        description          = "Platform admins observe capacity state; changes go through CI/CD."
      }
    },
    {
      for key, cap in local.capacities : "platform_admins_capacity_${key}" => {
        scope                = module.capacity[key].id
        role_definition_name = "Contributor"
        principal_id         = local.platform_admin_group_object_id
        principal_type       = "Group"
        description          = "Break-glass pause/resume and scale of the ${key} capacity."
      }
    }
  )
}
