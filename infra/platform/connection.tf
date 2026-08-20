# Shared GitHub source control connection.
#
# Created once in the platform root because a single connection serves all three
# workspaces, which each live in their own state file. The workspace root
# resolves it by display name rather than by ID, so no GUID has to be copied
# between states.
#
# The PAT is supplied as TF_VAR_github_pat and is NEVER written to a tfvars file.
# It is assigned to key_wo, a write-only attribute, so Terraform does not persist
# it in state either. Bump github_pat_version to push a rotated token.

resource "fabric_connection" "github" {
  count = var.github_pat == null ? 0 : 1

  display_name      = local.github_connection_name
  connectivity_type = "ShareableCloud"
  privacy_level     = "Organizational"

  connection_details = {
    type            = "GitHubSourceControl"
    creation_method = "GitHubSourceControl.Contents"
    parameters = [
      {
        name  = "url"
        value = "https://github.com/${var.github_owner}/${var.github_repository}"
      }
    ]
  }

  credential_details = {
    credential_type = "Key"
    key_credentials = {
      key_wo         = var.github_pat
      key_wo_version = var.github_pat_version
    }
  }
}
