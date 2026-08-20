output "id" {
  description = "Fabric workspace GUID. Consumed by fabric-cicd as the deployment target."
  value       = fabric_workspace.this.id
}

output "display_name" {
  description = "Fabric workspace display name."
  value       = fabric_workspace.this.display_name
}

output "capacity_id" {
  description = "Capacity GUID the workspace is assigned to."
  value       = fabric_workspace.this.capacity_id
}

output "identity_principal_id" {
  description = "Object ID of the workspace managed identity, or null when identity is disabled."
  value       = try(fabric_workspace.this.identity.service_principal_id, null)
}

output "onelake_endpoint" {
  description = "OneLake DFS endpoint for the workspace. Null until the workspace is assigned to an active capacity, since the Fabric API omits the endpoints block until then."
  value       = try(fabric_workspace.this.onelake_endpoints.dfs_endpoint, null)
}

output "onelake_blob_endpoint" {
  description = "OneLake Blob API endpoint for the workspace, or null when unassigned."
  value       = try(fabric_workspace.this.onelake_endpoints.blob_endpoint, null)
}

output "git_connection_state" {
  description = "Git connection state, or null when Git integration is disabled. ConnectedAndInitialized means the workspace and branch are in sync."
  value       = try(fabric_workspace_git.this[0].git_connection_state, null)
}

output "git_head" {
  description = "Commit hash the workspace is currently synced to, or null when Git integration is disabled."
  value       = try(fabric_workspace_git.this[0].git_sync_details.head, null)
}
