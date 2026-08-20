output "role_assignment_ids" {
  description = "Map of logical assignment name to the created role assignment ID."
  value       = { for k, v in azurerm_role_assignment.this : k => v.id }
}
