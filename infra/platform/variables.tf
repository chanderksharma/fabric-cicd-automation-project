variable "lane" {
  description = <<-EOT
    Deployment lane. Every resource name carries this suffix, so the two lanes
    can be built side by side in one tenant without colliding:

      ml -> built and operated from a workstation (docs/setup-manual-cli.md)
      gh -> built and operated by GitHub Actions (docs/setup-github-actions.md)

    Defaults to ml because a bare `terraform apply` is by definition the manual
    path. The workflows always set TF_VAR_lane=gh explicitly, so a local run can
    never write to the lane CI owns.

    An empty string means the unsuffixed estate that predates lanes. It exists
    so `terraform destroy` can still describe that estate; do not build with it.
  EOT
  type        = string
  default     = "ml"

  validation {
    condition     = contains(["gh", "ml", ""], var.lane)
    error_message = "lane must be gh, ml, or empty for the pre-lane estate."
  }
}

variable "tenant_id" {
  description = "Entra ID tenant GUID. Null resolves to the tenant of the current Azure CLI or OIDC session, which is almost always what you want."
  type        = string
  default     = null

  validation {
    condition     = var.tenant_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "subscription_id" {
  description = "Azure subscription GUID that hosts the Fabric capacity. Null resolves to the subscription of the current session, or to ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "prefix" {
  description = "Naming prefix for every resource, e.g. contoso-fab. Environment suffixes are appended by the workspace root, not here."
  type        = string
  default     = "contoso-fab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.prefix))
    error_message = "prefix must be 3-21 characters, start with a lowercase letter, and contain only lowercase letters, digits and hyphens."
  }
}

variable "location" {
  description = "Azure region for the resource group and Fabric capacity. Fabric quota is per region and defaults to zero, so verify the subscription has capacity units available before changing this."
  type        = string
  default     = "centralus"
}

variable "capacities" {
  description = <<-EOT
    Fabric capacities to provision, keyed by logical name. This map is the single
    switch that decides the capacity topology:

      { shared = { sku = "F2" } }
        -> one capacity shared by dev, test and prod (default, lowest cost)

      { nonprod = { sku = "F2" }, prod = { sku = "F8" } }
        -> dev/test share a small capacity, prod gets its own

      { dev = {...}, test = {...}, prod = {...} }
        -> fully dedicated capacity per environment

    The workspace root selects which capacity to bind to via the
    capacity_display_name variable in each envs/<env>.tfvars file.
  EOT
  type = map(object({
    sku                         = optional(string, "F2")
    location                    = optional(string)
    additional_admin_object_ids = optional(list(string), [])
    additional_admin_upns       = optional(list(string), [])
  }))
  default = {
    shared = {
      sku = "F2"
    }
  }

  validation {
    condition     = length(var.capacities) > 0
    error_message = "At least one capacity must be defined."
  }

  validation {
    condition = alltrue([
      for k in keys(var.capacities) : can(regex("^[a-z0-9]{2,12}$", k))
    ])
    error_message = "Capacity keys must be 2-12 lowercase alphanumeric characters; they become part of the Azure capacity name."
  }
}

variable "cicd_service_principal_object_id" {
  description = <<-EOT
    Object ID of the CI/CD service principal (the enterprise application object,
    NOT the app registration object ID). It is added as a capacity administrator
    so the Fabric provider can read the capacity and assign workspaces to it.

    Null falls back to whoever is running Terraform. That is correct for the ml
    lane, which has no CI principal: the operator is the administrator. The gh
    lane must set it, because the principal that applies is not the principal
    that needs standing access.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.cicd_service_principal_object_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.cicd_service_principal_object_id))
    error_message = "cicd_service_principal_object_id must be a GUID."
  }
}

variable "platform_admin_group_name" {
  description = "Display name of the Entra security group holding Fabric platform administrators."
  type        = string
  default     = "sg-fabric-platform-admins"
}

variable "platform_admin_group_object_id" {
  description = <<-EOT
    Object ID of the platform admin group.

    Supplying it is what lets the deployment identity run without any Microsoft
    Graph permission: the directory lookups are the only reason this root reads
    Entra. Bootstrap resolves the group already and publishes the ID.

    When set, group membership is no longer expanded into capacity
    administrators, so list any human capacity admin in platform_admin_upns.

    Null looks the group up by display name, which requires Directory.Read.All.
  EOT
  type        = string
  default     = null

  validation {
    condition     = coalesce(var.platform_admin_group_object_id, "") == "" || can(regex("^[0-9a-fA-F-]{36}$", var.platform_admin_group_object_id))
    error_message = "platform_admin_group_object_id must be a GUID, or empty to look the group up by name."
  }
}

variable "platform_admin_upns" {
  description = "Optional additional capacity administrators expressed as user principal names. Prefer the admin group; use this only for break-glass accounts."
  type        = list(string)
  default     = []
}

variable "create_deployment_pipeline" {
  description = <<-EOT
    Create a Fabric deployment pipeline spanning the dev, test and prod
    workspaces.

    A deployment pipeline promotes items workspace-to-workspace, which is a
    second promotion path alongside branch-per-environment Git integration.
    Running both against the same workspace means two writers: a stage deploy
    lands items that Git then reports as uncommitted workspace changes.

    Enable this only if the pipeline is the promotion mechanism and Git
    integration is reduced to dev for authoring, or if the pipeline is used
    purely to compare stages rather than to deploy.

    The workspaces must already exist; the pipeline references them by name.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Base tags applied to every resource. managed-by is forced to terraform."
  type        = map(string)
  default = {
    env         = "platform"
    owner       = "fabric-platform-team"
    cost-center = "CC-0000"
  }

  validation {
    condition     = alltrue([for k in ["env", "owner", "cost-center"] : contains(keys(var.tags), k)])
    error_message = "tags must include env, owner and cost-center."
  }
}
