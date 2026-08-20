resource "fabric_workspace" "this" {
  display_name = var.display_name
  description  = var.description
  capacity_id  = var.capacity_id

  skip_capacity_state_validation = var.skip_capacity_state_validation

  identity = var.enable_workspace_identity ? { type = "SystemAssigned" } : null
}

resource "fabric_workspace_role_assignment" "this" {
  for_each = var.role_assignments

  workspace_id = fabric_workspace.this.id
  role         = each.value.role

  principal = {
    id   = each.value.principal_id
    type = each.value.principal_type
  }
}

resource "fabric_workspace_git" "this" {
  count = var.git_integration == null ? 0 : 1

  workspace_id            = fabric_workspace.this.id
  initialization_strategy = var.git_integration.initialization_strategy

  git_provider_details = {
    git_provider_type = var.git_integration.provider_type
    owner_name        = var.git_integration.owner_name
    organization_name = var.git_integration.organization_name
    project_name      = var.git_integration.project_name
    repository_name   = var.git_integration.repository_name
    branch_name       = var.git_integration.branch_name
    directory_name    = var.git_integration.directory_name
  }

  git_credentials = {
    source        = var.git_integration.credentials_source
    connection_id = var.git_integration.connection_id
  }

  options = {
    allow_override_items = var.git_integration.allow_override_items
  }

  # Connecting requires workspace Admin, which the role assignments grant.
  depends_on = [fabric_workspace_role_assignment.this]

  lifecycle {
    precondition {
      condition     = var.git_integration.connection_id != null
      error_message = "git_integration is set but no connection ID was resolved. Set TF_VAR_github_connection_id, or in CI the GitHub Environment variable FABRIC_GITHUB_CONNECTION_ID."
    }
  }
}
