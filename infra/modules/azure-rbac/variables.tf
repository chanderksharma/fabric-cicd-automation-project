variable "assignments" {
  description = <<-EOT
    Azure-plane role assignments to create, keyed by a stable logical name so
    that reordering the input never forces a replacement.

      scope                = ARM resource ID the role applies to
      role_definition_name = built-in role name, e.g. "Contributor"
      principal_id         = Entra object ID of a group, user or service principal
      principal_type       = "Group" | "ServicePrincipal" | "User"
      description          = why this assignment exists (surfaces in the portal)
  EOT
  type = map(object({
    scope                = string
    role_definition_name = string
    principal_id         = string
    principal_type       = optional(string, "Group")
    description          = optional(string, "Managed by Terraform")
  }))
  default = {}

  validation {
    condition = alltrue([
      for a in values(var.assignments) :
      contains(["Group", "ServicePrincipal", "User"], a.principal_type)
    ])
    error_message = "principal_type must be one of Group, ServicePrincipal, User."
  }
}
