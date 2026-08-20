variable "github_owner" {
  description = "GitHub organisation or user that owns the repository holding the Fabric item source."
  type        = string
  default     = "chandsharma_microsoft"
}

variable "github_repository" {
  description = <<-EOT
    Repository that Fabric syncs workspace items with. This is the items
    repository, not the one holding this Terraform code.

    The two are deliberately separate: Terraform is promoted by pull request
    into main, while item branches are written by Fabric itself. Keeping them
    apart stops item commits from appearing in infrastructure reviews and
    vice versa.
  EOT
  type        = string
  default     = "fabric-workspace-items"
}

variable "github_connection_name" {
  description = "Display name of the Fabric GitHub source control connection. Null derives <prefix>-<lane>-items, which keeps the two lanes on separate connections so revoking one PAT cannot break the other."
  type        = string
  default     = null
}

variable "github_pat" {
  description = <<-EOT
    GitHub personal access token with Contents read/write on the repository.
    Supply it as TF_VAR_github_pat, never in a tfvars file.

    Leave null to skip creating the connection, which is the right choice when
    the connection is managed outside Terraform.

    Assigned to a write-only provider attribute, so Terraform does not persist
    it in state. Rotating the token therefore also requires incrementing
    github_pat_version, otherwise Terraform sees no change to push.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "github_pat_version" {
  description = "Increment after rotating github_pat. Write-only attributes are absent from state, so this is the only signal Terraform has that the credential changed."
  type        = string
  default     = "1"
}
