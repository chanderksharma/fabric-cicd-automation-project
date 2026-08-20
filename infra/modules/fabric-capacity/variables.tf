variable "name" {
  description = "Fabric capacity name. Azure requires 3-63 lowercase alphanumeric characters with no hyphens; the module normalises the value before use."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]{3,63}$", var.name))
    error_message = "name must be 3-63 characters and contain only letters, digits and hyphens (hyphens are stripped automatically)."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group that hosts the Fabric capacity."
  type        = string
}

variable "location" {
  description = "Azure region for the capacity. Must be a region where Microsoft Fabric capacity is available and where the subscription holds a non-zero capacity-unit quota."
  type        = string
  default     = "centralus"
}

variable "sku" {
  description = "Fabric capacity SKU. F2 is the cheapest and is the default for cost control; scale up for production throughput."
  type        = string
  default     = "F2"

  validation {
    condition = contains(
      ["F2", "F4", "F8", "F16", "F32", "F64", "F128", "F256", "F512", "F1024", "F2048"],
      var.sku
    )
    error_message = "sku must be one of F2, F4, F8, F16, F32, F64, F128, F256, F512, F1024, F2048."
  }
}

variable "administration_members" {
  description = <<-EOT
    Capacity administrators. Accepts user principal names (UPNs) for humans and
    object IDs for service principals and managed identities. The CI/CD service
    principal MUST be present here, otherwise the Fabric provider cannot read the
    capacity and workspace-to-capacity assignment fails.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.administration_members) > 0
    error_message = "At least one capacity administrator is required."
  }
}

variable "tags" {
  description = "Tags applied to the capacity."
  type        = map(string)
  default     = {}
}
