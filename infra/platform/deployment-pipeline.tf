# Fabric deployment pipeline.
#
# Lives in the platform root because it spans all three environments, which each
# have their own state file. Workspaces are resolved by display name rather than
# by GUID so nothing has to be copied between states.
#
# Deliberately does NOT depend on the workspace root: the pipeline references
# workspaces that already exist, and creating it does not deploy anything. Stage
# deployment is an operation, not a resource, and is triggered separately.

data "fabric_workspace" "stage" {
  for_each = var.create_deployment_pipeline ? toset(["dev", "test", "prod"]) : toset([])

  display_name = "${local.name_prefix}-${each.key}"

  # The capacity may be paused outside working hours; that does not affect a
  # metadata read.
  skip_capacity_state_validation = true
}

resource "fabric_deployment_pipeline" "this" {
  count = var.create_deployment_pipeline ? 1 : 0

  display_name = "${local.name_prefix}-release"
  description  = "Promotes Fabric items from dev to test to prod in the ${var.lane} lane. Managed by Terraform."

  stages = [
    {
      display_name = "Development"
      description  = "Authoring workspace. Items arrive here from the dev branch."
      is_public    = false
      workspace_id = data.fabric_workspace.stage["dev"].id
    },
    {
      display_name = "Test"
      description  = "Validation workspace. Receives promoted items from Development."
      is_public    = false
      workspace_id = data.fabric_workspace.stage["test"].id
    },
    {
      display_name = "Production"
      description  = "Production workspace. Receives promoted items from Test."
      is_public    = true
      workspace_id = data.fabric_workspace.stage["prod"].id
    }
  ]
}

# Deploying between stages requires Admin on the pipeline, which is separate
# from workspace roles.
#
# Fabric grants the creator Admin, and the creator is whichever principal
# Terraform runs as, so assigning it again returns
# DeploymentPipelineRoleAssignmentAlreadyExists. Only the durable group
# assignment is managed here, matching the workspace root.
resource "fabric_deployment_pipeline_role_assignment" "admins" {
  for_each = var.create_deployment_pipeline ? {
    platform_admins = data.azuread_group.platform_admins.object_id
  } : {}

  deployment_pipeline_id = fabric_deployment_pipeline.this[0].id
  role                   = "Admin"

  principal = {
    id   = each.value
    type = "Group"
  }
}
