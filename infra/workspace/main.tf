data "azuread_client_config" "current" {}

data "azuread_group" "platform_admins" {
  display_name     = var.platform_admin_group_name
  security_enabled = true
}

data "azuread_group" "data_engineers" {
  display_name     = var.data_engineer_group_name
  security_enabled = true
}

data "azuread_group" "analysts" {
  display_name     = var.analyst_group_name
  security_enabled = true
}

# The Fabric API addresses capacities by GUID, while azurerm_fabric_capacity
# returns an ARM resource ID. This data source performs the translation.
# It requires the caller to be a capacity administrator, which the platform root
# guarantees for the CI/CD principal.
data "fabric_capacity" "assigned" {
  count = local.capacity_name == null ? 0 : 1

  display_name = lower(replace(local.capacity_name, "-", ""))
}

module "workspace" {
  source = "../modules/fabric-workspace"

  display_name                   = local.workspace_name
  description                    = local.description
  capacity_id                    = try(data.fabric_capacity.assigned[0].id, null)
  enable_workspace_identity      = var.enable_workspace_identity
  skip_capacity_state_validation = var.skip_capacity_state_validation
  role_assignments               = local.role_assignments
  git_integration                = local.git_integration
}
