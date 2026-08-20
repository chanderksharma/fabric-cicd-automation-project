output "lane" {
  description = "Deployment lane this state file owns."
  value       = var.lane
}

output "name_prefix" {
  description = "Lane-scoped naming prefix. Workspaces are <name_prefix>-<environment>."
  value       = local.name_prefix
}

output "resource_group_name" {
  description = "Resource group holding the Fabric capacities."
  value       = azurerm_resource_group.fabric.name
}

output "capacity_names" {
  description = "Map of logical capacity key to the Azure capacity name. Feed the relevant value into envs/<env>.tfvars as capacity_display_name."
  value       = { for k, m in module.capacity : k => m.name }
}

output "capacity_ids" {
  description = "Map of logical capacity key to ARM resource ID."
  value       = { for k, m in module.capacity : k => m.id }
}

output "capacity_skus" {
  description = "Map of logical capacity key to provisioned SKU."
  value       = { for k, m in module.capacity : k => m.sku }
}

output "github_connection_id" {
  description = "Fabric GitHub source control connection GUID, or null when github_pat was not supplied. The workspace root resolves this by display name rather than consuming the value directly."
  value       = try(fabric_connection.github[0].id, null)
}

output "github_connection_name" {
  description = "Display name of the GitHub connection created for this lane."
  value       = local.github_connection_name
}

output "deployment_pipeline_id" {
  description = "Fabric deployment pipeline GUID, or null when create_deployment_pipeline is false."
  value       = try(fabric_deployment_pipeline.this[0].id, null)
}

output "deployment_pipeline_stages" {
  description = "Stage name to stage GUID, for triggering a stage deployment."
  value       = try({ for s in fabric_deployment_pipeline.this[0].stages : s.display_name => s.id }, {})
}
