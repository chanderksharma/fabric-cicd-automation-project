variable "display_name" {
  description = "Fabric workspace display name, e.g. contoso-fab-dev. Must be unique within the tenant."
  type        = string

  validation {
    condition     = length(var.display_name) >= 3 && length(var.display_name) <= 256
    error_message = "display_name must be between 3 and 256 characters."
  }

  validation {
    condition     = !can(regex("(?i)^(admin|my ?workspace)$", trimspace(var.display_name)))
    error_message = "Fabric reserves the names 'Admin' and 'My Workspace'."
  }
}

variable "description" {
  description = "Workspace description shown in the Fabric portal."
  type        = string
  default     = "Managed by Terraform. Item content arrives through Git integration."
}

variable "capacity_id" {
  description = "Fabric capacity GUID (not the ARM resource ID) the workspace is assigned to. Pass null to leave the workspace on shared/trial capacity."
  type        = string
  default     = null

  validation {
    condition = var.capacity_id == null || can(regex(
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      coalesce(var.capacity_id, "00000000-0000-0000-0000-000000000000")
    ))
    error_message = "capacity_id must be a GUID. Use the fabric_capacity data source, not the azurerm_fabric_capacity ARM id."
  }
}

variable "enable_workspace_identity" {
  description = "Create a workspace managed identity. Required for OneLake shortcuts and trusted-workspace access to firewalled storage."
  type        = bool
  default     = true
}

variable "skip_capacity_state_validation" {
  description = <<-EOT
    Skip the provider's check that the assigned capacity is Active. Set to true
    only for environments whose capacity is routinely paused, and only when the
    caller cannot list capacities.

    Warning: with this enabled the provider cannot detect a suspended capacity,
    and a subsequent apply may fail to read workspace items. Leave false unless
    you have accepted that risk.
  EOT
  type        = bool
  default     = false
}

variable "role_assignments" {
  description = <<-EOT
    Fabric-plane workspace role assignments, keyed by a stable logical name.

      principal_id   = Entra object ID of the group or service principal
      principal_type = "Group" | "User" | "ServicePrincipal" | "ServicePrincipalProfile"
      role           = "Admin" | "Member" | "Contributor" | "Viewer"
  EOT
  type = map(object({
    principal_id   = string
    principal_type = optional(string, "Group")
    role           = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for r in values(var.role_assignments) :
      contains(["Admin", "Member", "Contributor", "Viewer"], r.role)
    ])
    error_message = "role must be one of Admin, Member, Contributor, Viewer."
  }

  validation {
    condition = alltrue([
      for r in values(var.role_assignments) :
      contains(["Group", "User", "ServicePrincipal", "ServicePrincipalProfile"], r.principal_type)
    ])
    error_message = "principal_type must be one of Group, User, ServicePrincipal, ServicePrincipalProfile."
  }

}
