# Platform-scope structural configuration. Safe to commit: it describes the
# infrastructure, not the tenant it lands in.
#
# Tenant-specific identifiers are deliberately absent and are supplied through
# environment variables instead, so the same file works in every tenant:
#
#   TF_VAR_tenant_id
#   TF_VAR_subscription_id
#   TF_VAR_cicd_service_principal_object_id
#
# Locally: scripts/Load-Env.ps1 reads them from .env
# In CI    : the workflows read them from GitHub Environment variables

prefix = "contoso-fab"

# centralus is the only region with Fabric capacity quota on this subscription
# (limit 512 CU; canadacentral and others are 0). Check before changing:
#   az rest --method GET --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Fabric/locations/<region>/usages?api-version=2023-11-01"
location = "centralus"

platform_admin_group_name = "sg-fabric-platform-admins"

# Promotion path is still branch-per-environment Git integration. The pipeline
# is created for stage comparison; deploying through it as well would make two
# writers to test and prod.
create_deployment_pipeline = true

# Single F2 shared by dev, test and prod.
# To give prod its own capacity, replace with:
#   capacities = {
#     nonprod = { sku = "F2" }
#     prod    = { sku = "F8" }
#   }
# and point envs/prod.tfvars at capacity_display_name = "contoso-fab-prod".
capacities = {
  shared = {
    sku = "F2"
  }
}

tags = {
  env         = "platform"
  owner       = "fabric-platform-team"
  cost-center = "CC-1042"
}
