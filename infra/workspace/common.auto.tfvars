# Auto-loaded by Terraform: any *.auto.tfvars file in the working directory is
# read without a -var-file flag.
#
# Values here are identical for dev, test and prod and are safe to commit.
# Tenant-specific identifiers come from environment variables instead:
#
#   TF_VAR_tenant_id
#   TF_VAR_cicd_service_principal_object_id
#
# Anything that differs per environment stays in envs/<environment>.tfvars,
# which must still be passed explicitly - that is deliberate, so a plan can
# never target the wrong environment by omission.

prefix = "contoso-fab"

platform_admin_group_name = "sg-fabric-platform-admins"
data_engineer_group_name  = "sg-fabric-data-engineers"
analyst_group_name        = "sg-fabric-analysts"
