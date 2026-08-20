variable "github_connection_id" {
  description = <<-EOT
    GUID of the Fabric GitHub source control connection created by the platform
    root, supplied as TF_VAR_github_connection_id.

    Passed explicitly rather than looked up, because the fabric_connections data
    source reads every connection in the tenant and errors with "unexpected
    connectivity type" if any one of them is a type the provider cannot parse.

    Read it from the platform root:
      terraform -chdir=infra/platform output -raw github_connection_id
  EOT
  type        = string
  default     = null

  validation {
    condition = var.github_connection_id == null || can(regex(
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      var.github_connection_id
    ))
    error_message = "github_connection_id must be a GUID."
  }
}

variable "enable_git_integration" {
  description = "Connect the workspace to a Git branch. Set false to build the workspace without source control, for example while the GitHub connection is being recreated."
  type        = bool
  default     = true
}

variable "git_provider_type" {
  description = "Source control provider. GitHub or AzureDevOps."
  type        = string
  default     = "GitHub"
}

variable "git_owner_name" {
  description = "GitHub organisation or user owning the items repository."
  type        = string
  default     = "chandsharma_microsoft"
}

variable "git_repository_name" {
  description = "Repository holding Fabric item source. Separate from the repository holding this Terraform code."
  type        = string
  default     = "fabric-workspace-items"
}

variable "git_branch_name" {
  description = <<-EOT
    Branch this workspace syncs with. Null derives <lane>-<environment>, giving
    six branches across the two lanes: gh-dev, gh-test, gh-prod, ml-dev,
    ml-test, ml-prod.

    The lane must be part of the branch name. Two workspaces pointed at one
    branch do not share it, they overwrite each other on every sync.
  EOT
  type        = string
  default     = null
}

variable "git_directory_name" {
  description = "Path within the repository that Fabric syncs. Items live in their own repository, so the root is correct."
  type        = string
  default     = "/"
}

variable "git_initialization_strategy" {
  description = "Which side wins when connecting a workspace and a branch that both already hold items. PreferRemote or PreferWorkspace."
  type        = string
  default     = "PreferRemote"
}

variable "git_allow_override_items" {
  description = "Allow Git to overwrite an item that already exists in the workspace. Required when the branch is the source of truth, otherwise connecting a non-empty workspace fails with OverrideItemsNotAllowed."
  type        = bool
  default     = true
}

variable "git_integration" {
  description = <<-EOT
    Full override of the Git integration block. Null builds it from the
    git_* variables above, which is the normal path.

    Supply this only to express something the discrete variables cannot, such
    as an Azure DevOps project. Whatever is supplied is merged over the derived
    values rather than replacing them.

    Important: a workspace must not be both a Git source of truth and a push
    target for an external deployment tool. Two writers fight over head
    tracking, and every automated publish shows up as an uncommitted workspace
    change.
  EOT
  type = object({
    provider_type           = optional(string)
    owner_name              = optional(string)
    organization_name       = optional(string)
    project_name            = optional(string)
    repository_name         = optional(string)
    branch_name             = optional(string)
    directory_name          = optional(string)
    connection_id           = optional(string)
    credentials_source      = optional(string)
    initialization_strategy = optional(string)
    allow_override_items    = optional(bool)
  })
  default = null
}
