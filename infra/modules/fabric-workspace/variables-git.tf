variable "git_integration" {
  description = <<-EOT
    Connects the workspace to a Git repository. Null disables Git integration,
    which is the correct setting for a workspace that receives items some other
    way.

    A workspace must never be both a Git source of truth and a CI/CD push target
    on the same branch: humans commit from the workspace, or automation pushes to
    Git, never both. In this repository every environment syncs with its own
    branch, and content promotes by merging one branch into the next.

      provider_type           "GitHub" or "AzureDevOps"
      owner_name              GitHub owner. GitHub only.
      organization_name       Azure DevOps organisation. Azure DevOps only.
      project_name            Azure DevOps project. Azure DevOps only.
      repository_name         Repository holding the item source
      branch_name             Branch the workspace syncs with. Not the branch
                              CI deploys from.
      directory_name          Path within the repository, e.g. /workspace
      connection_id           Fabric connection GUID. Required for GitHub, and
                              for Azure DevOps when source is ConfiguredConnection.
                              The Terraform provider cannot create connections;
                              make it once in the Fabric portal.
      credentials_source      "ConfiguredConnection" or, for Azure DevOps only,
                              "Automatic"
      initialization_strategy "PreferRemote" pulls the repository into the
                              workspace; "PreferWorkspace" pushes the workspace
                              into the repository. Changing it recreates the
                              connection.
      allow_override_items    Overwrite workspace items during update from Git
  EOT
  type = object({
    provider_type           = optional(string, "GitHub")
    owner_name              = optional(string)
    organization_name       = optional(string)
    project_name            = optional(string)
    repository_name         = string
    branch_name             = string
    directory_name          = optional(string, "/workspace")
    connection_id           = optional(string)
    credentials_source      = optional(string, "ConfiguredConnection")
    initialization_strategy = optional(string, "PreferRemote")
    allow_override_items    = optional(bool, false)
  })
  default = null

  validation {
    condition = var.git_integration == null || contains(
      ["GitHub", "AzureDevOps"], try(var.git_integration.provider_type, "")
    )
    error_message = "provider_type must be GitHub or AzureDevOps."
  }

  validation {
    condition = var.git_integration == null || contains(
      ["PreferRemote", "PreferWorkspace"], try(var.git_integration.initialization_strategy, "")
    )
    error_message = "initialization_strategy must be PreferRemote or PreferWorkspace."
  }

  validation {
    # GitHub has no Automatic credential flow, so a connection must already exist.
    condition = var.git_integration == null || try(var.git_integration.provider_type, "") != "GitHub" || (
      try(var.git_integration.credentials_source, "") == "ConfiguredConnection" &&
      try(var.git_integration.connection_id, null) != null
    )
    error_message = "GitHub requires credentials_source = ConfiguredConnection and a connection_id. The ID normally arrives as TF_VAR_github_connection_id, or in CI as the GitHub Environment variable FABRIC_GITHUB_CONNECTION_ID. If no connection exists yet, create one in the Fabric portal under Manage connections and gateways."
  }

  validation {
    condition = var.git_integration == null || try(var.git_integration.provider_type, "") != "GitHub" || (
      try(var.git_integration.owner_name, null) != null
    )
    error_message = "owner_name is required when provider_type is GitHub."
  }

  validation {
    condition = var.git_integration == null || try(var.git_integration.provider_type, "") != "AzureDevOps" || (
      try(var.git_integration.organization_name, null) != null &&
      try(var.git_integration.project_name, null) != null
    )
    error_message = "organization_name and project_name are required when provider_type is AzureDevOps."
  }
}
