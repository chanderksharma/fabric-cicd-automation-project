output "workspace_id" {
  description = "Fabric workspace GUID. Never hardcode this value; read it from here."
  value       = module.workspace.id
}

output "lane" {
  description = "Deployment lane this workspace belongs to."
  value       = var.lane
}

output "workspace_name" {
  description = "Fabric workspace display name."
  value       = module.workspace.display_name
}

output "capacity_id" {
  description = "Fabric capacity GUID the workspace is bound to, or null when unassigned."
  value       = module.workspace.capacity_id
}

output "workspace_identity_principal_id" {
  description = "Object ID of the workspace managed identity, for granting storage access to source systems."
  value       = module.workspace.identity_principal_id
}

output "onelake_endpoint" {
  description = "OneLake DFS endpoint for this workspace. Null until the workspace is assigned to an active capacity."
  value       = module.workspace.onelake_endpoint
}

output "environment" {
  description = "Environment key this state file owns."
  value       = var.environment
}

output "git_integration_enabled" {
  description = "False when Git integration was requested but skipped because no connection ID was available. Set TF_VAR_github_connection_id and re-apply."
  value       = local.git_enabled
}

output "git_branch_name" {
  description = "Branch this workspace syncs with, or null when Git integration is off."
  value       = try(local.git_integration.branch_name, null)
}

output "git_connection_state" {
  description = "Git connection state for this workspace, or null when Git integration is disabled."
  value       = module.workspace.git_connection_state
}
