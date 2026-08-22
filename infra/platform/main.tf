data "azurerm_client_config" "current" {}

data "azuread_client_config" "current" {}

# Resolves the caller's UPN when the caller is a user, and returns nothing when
# it is a service principal. That difference is what lets the same configuration
# serve a local operator and a CI principal without being told which it is.
data "azuread_users" "caller" {
  count = local.lookup_directory ? 1 : 0

  object_ids     = [data.azuread_client_config.current.object_id]
  ignore_missing = true
}

data "azuread_group" "platform_admins" {
  count = local.lookup_directory ? 1 : 0

  display_name     = var.platform_admin_group_name
  security_enabled = true
}

# The Fabric capacity API rejects group principals in administration_members:
# "All provided principals must be existing, user or service principals".
# Membership is still managed on the group; this expands it to the user
# principal names the API will accept. ignore_missing skips any member that is
# not a user, such as a nested group or a service principal.
data "azuread_users" "platform_admins" {
  count = local.lookup_directory ? 1 : 0

  object_ids     = data.azuread_group.platform_admins[0].members
  ignore_missing = true
}

resource "azurerm_resource_group" "fabric" {
  name     = "rg-${local.name_prefix}-fabric"
  location = var.location
  tags     = local.base_tags
}

module "capacity" {
  source   = "../modules/fabric-capacity"
  for_each = local.capacities

  name                   = each.value.name
  resource_group_name    = azurerm_resource_group.fabric.name
  location               = each.value.location
  sku                    = each.value.sku
  administration_members = each.value.admins

  tags = merge(local.base_tags, {
    "capacity-role" = each.key
    "sku"           = each.value.sku
  })
}

module "azure_rbac" {
  source = "../modules/azure-rbac"

  assignments = local.azure_role_assignments
}
