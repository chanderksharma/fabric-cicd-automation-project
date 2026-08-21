variable "lane" {
  description = "Deployment lane, gh or ml. Must match the lane the platform root was applied with, otherwise the capacity lookup finds nothing. Empty describes the unsuffixed estate that predates lanes, so destroy can still reach it. See the lane variable in ../platform."
  type        = string
  default     = "ml"

  validation {
    condition     = contains(["gh", "ml", ""], var.lane)
    error_message = "lane must be gh, ml, or empty for the pre-lane estate."
  }
}

variable "tenant_id" {
  description = "Entra ID tenant GUID. Null resolves to the tenant of the current session."
  type        = string
  default     = null

  validation {
    condition     = var.tenant_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "environment" {
  description = "Environment this state file owns. Drives the workspace name, the role model and the Git branch."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of dev, test, prod."
  }
}

variable "prefix" {
  description = "Naming prefix. The workspace is named <prefix>-<environment>."
  type        = string
  default     = "contoso-fab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.prefix))
    error_message = "prefix must be 3-21 characters, start with a lowercase letter, and contain only lowercase letters, digits and hyphens."
  }
}

variable "capacity_key" {
  description = "Logical capacity key from the platform root's capacities map. Combined with the prefix and lane to find the capacity, so nothing has to be copied between state files."
  type        = string
  default     = "shared"
}

variable "capacity_display_name" {
  description = <<-EOT
    Azure name of the Fabric capacity this environment binds to. Null derives
    <prefix>-<lane>-<capacity_key>, which matches what the platform root emits
    as capacity_names, so the common case needs no value at all.

    Set explicitly only to point an environment at a capacity the platform root
    does not own. Set capacity_key to "" to leave the workspace unassigned,
    which keeps apply working while a capacity is suspended or absent.
  EOT
  type        = string
  default     = null
}

variable "cicd_service_principal_object_id" {
  description = "Object ID of the CI/CD service principal. When set, Terraform verifies Fabric granted it the automatic creator Admin role; that API-owned assignment is not recreated."
  type        = string
  default     = null

  validation {
    condition     = var.cicd_service_principal_object_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.cicd_service_principal_object_id))
    error_message = "cicd_service_principal_object_id must be a GUID."
  }
}

variable "platform_admin_group_name" {
  description = "Entra security group display name for Fabric platform administrators."
  type        = string
  default     = "sg-fabric-platform-admins"
}

variable "data_engineer_group_name" {
  description = "Entra security group display name for data engineers who author Fabric items."
  type        = string
  default     = "sg-fabric-data-engineers"
}

variable "analyst_group_name" {
  description = "Entra security group display name for report consumers and analysts."
  type        = string
  default     = "sg-fabric-analysts"
}

variable "enable_workspace_identity" {
  description = "Create a workspace managed identity for OneLake shortcuts and trusted workspace access."
  type        = bool
  default     = true
}

variable "skip_capacity_state_validation" {
  description = "Allow apply to proceed while the assigned capacity is paused. Useful for a dev capacity that is suspended outside working hours; leave false for test and prod."
  type        = bool
  default     = false
}

variable "role_overrides" {
  description = <<-EOT
    Optional per-environment override of the human role model. Keys must be one
    of platform_admins, data_engineers, analysts. Values must be a valid Fabric
    workspace role. The CI/CD service principal's automatic Admin role cannot
    be overridden here.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.role_overrides) :
      contains(["platform_admins", "data_engineers", "analysts"], k)
    ])
    error_message = "role_overrides keys must be platform_admins, data_engineers or analysts."
  }

  validation {
    condition = alltrue([
      for v in values(var.role_overrides) :
      contains(["Admin", "Member", "Contributor", "Viewer"], v)
    ])
    error_message = "role_overrides values must be Admin, Member, Contributor or Viewer."
  }
}

variable "workspace_description" {
  description = "Optional override for the workspace description."
  type        = string
  default     = null
}
