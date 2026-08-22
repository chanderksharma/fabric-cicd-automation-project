# Manual Setup with Azure CLI and Terraform

Step-by-step build of the Microsoft Fabric platform from an empty subscription using local tooling, for an operator with Global Administrator and subscription Owner.

## Who this is for

An operator holding **Global Administrator** in Entra ID and **Owner** on the target Azure subscription, building the platform from a local workstation. Everything runs from your machine; no CI is involved.

For the automated path see [setup-github-actions.md](setup-github-actions.md). The two are alternatives, not sequential.

## What gets built

| Layer | Resources |
| --- | --- |
| Bootstrap | State storage account, network security perimeter, app registration, federated credentials, Azure RBAC |
| Platform | Resource group, Fabric F2 capacity, capacity admins, GitHub connection, deployment pipeline |
| Workspaces | `<prefix>-dev`, `<prefix>-test`, `<prefix>-prod` with role assignments and Git integration |
| Items | Two Git repositories: one for Terraform, one for Fabric item source |

## Prerequisites

### Tooling

```powershell
az version                 # 2.60 or later
terraform version          # 1.11 or later, required for write-only attributes
python --version           # 3.9 to 3.13
$PSVersionTable.PSVersion  # PowerShell 7.x
az extension add --name microsoft-fabric --allow-preview true
```

The extension is named `microsoft-fabric`, not `fabric`. Without it, `az fabric` silently prompts to auto-install and appears to hang when its output is piped.

### Confirm your roles

```powershell
az login
az account show --query "{sub:name, id:id, tenant:tenantId}" -o yaml

az rest --method GET --url "https://graph.microsoft.com/v1.0/me/memberOf" -o json |
  ConvertFrom-Json | Select-Object -ExpandProperty value |
  Where-Object { $_.'@odata.type' -match 'directoryRole' } |
  Select-Object displayName
```

You need `Global Administrator` in that list. Owner on the subscription is separate and equally required.

That query returns roles that are **active**, which is the point. If your roles are
assigned through Privileged Identity Management, activate them before you start:
an eligible-but-inactive role behaves exactly like not having it. Global Reader is
the usual trap, because it reads everything, so every diagnostic command succeeds
and only the writes fail.

| Task in this guide | Minimum active role |
|--------------------|---------------------|
| Create the security groups and add members | Groups Administrator, User Administrator or Global Administrator |
| Create and consent the app registrations | Privileged Role Administrator or Global Administrator |
| Change Fabric tenant settings | Fabric Administrator, Power BI Administrator or Global Administrator |
| Create Azure resources and assign roles | Owner on the subscription |

### The fabric-admin-cli application

Step 2 needs an app registration named `fabric-admin-cli`. The script creates one
on first run, so there is nothing to prepare unless your account cannot consent to
Graph permissions.

| Property | Value |
|----------|-------|
| Name | `fabric-admin-cli` |
| Client type | Public client, device code flow. No secret to store or rotate |
| API permission | Power BI Service `Tenant.ReadWrite.All`, **delegated**, admin-consented |
| Sign-in audience | Single tenant |

The Azure CLI's own application requests only `user_impersonation` on the Power BI
Service, so `az rest` cannot reach `/v1/admin/*` no matter which directory roles
you hold. This registration exists solely to obtain a token carrying the admin
scope, and you sign in through it interactively.

It is created once per tenant, survives teardown, and is shared with the GitHub
Actions lane. If your account cannot consent, ask an administrator to create the
registration with that delegated permission granted; the script reuses an existing
one.

### Check Fabric capacity quota

This is the single most common late failure. Quota is per region and **defaults to zero**, so a region that offers Fabric may still reject capacity creation.

```powershell
$sub = az account show --query id -o tsv
foreach ($region in 'centralus','eastus','eastus2','westeurope','canadacentral') {
    $r = az rest --method GET --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Fabric/locations/$region/usages?api-version=2023-11-01" -o json 2>$null
    if ($r) { "$region : $(($r | ConvertFrom-Json).value[0].limit) CU limit" }
}
```

Pick a region with a non-zero limit and use it consistently below.

### Create the items repository

Fabric item source lives in its own repository, separate from Terraform. Keeping them apart stops item commits appearing in infrastructure reviews, and lets Fabric write to branches without touching your Terraform code.

Create `fabric-workspace-items` on GitHub, then:

```powershell
cd c:\code\github
git clone https://github.com/<owner>/fabric-workspace-items.git
cd fabric-workspace-items
git checkout -b ml-dev
git commit -q --allow-empty -m "chore: initialise"
git push -u origin ml-dev
git branch ml-test ml-dev; git branch ml-prod ml-dev
git push origin ml-test ml-prod
```

All three branches from the same commit. That is what keeps later promotion diffs limited to real item changes.

The `ml-` prefix is not decoration. If this lane and the GitHub Actions lane shared a branch, their two workspaces would overwrite each other on every sync. The lane belongs in the branch name for the same reason it belongs in the workspace name.

To name the estate after something other than the lane, pass
`-WorkspacePrefix my-contoso` to the bootstrap in the next step and use
`my-contoso-dev`, `my-contoso-test` and `my-contoso-prod` as the branch names
here instead. Workspaces and branches then share one stem, so a branch name says
which workspace owns it.

## Step 1: Bootstrap

Two scripts, because they have different lifetimes. The state foundation is created once for the tenant and shared by both lanes; the bootstrap runs once per lane.

### 1a. State foundation, once for the tenant

```powershell
cd c:\code\github\fabric-cicd-automation-project

./scripts/New-StateFoundation.ps1 -UpdateBackendConfigs
```

It prompts for the storage account name, offering whatever `infra/platform/platform.backend.hcl` currently names as the default. Pass `-StorageAccount <name>` to skip the prompt.

Before creating anything it checks the name three ways, because "not in my subscription" and "free" are not the same thing:

| Result | What happens |
| --- | --- |
| Exists in your subscription | Reused. Nothing is recreated |
| Exists in another tenant | Stops with a clear message. The namespace is global |
| Available | Created |

This creates the state resource group and storage account, the network security perimeter with its access rules and association, **one container per lane** (`tfstate-gh` and `tfstate-ml`), and the `CanNotDelete` lock.

A container per lane rather than a shared container with different blob names, because an RBAC assignment can be scoped to a container and a blob prefix cannot. If you ever need to give CI access to its own state without handing it the manual lane's, the boundary is already there.

Order matters inside the script and is not obvious: governance policy forces the account to `SecuredByPerimeter`, so the account is unreachable until the perimeter association exists, and `publicNetworkAccess` will not accept that value until it does. Containers therefore cannot be created until the perimeter is in place, which is why the script retries for several minutes on the first one.

`-UpdateBackendConfigs` rewrites the four committed `*.backend.hcl` files to match. Omit it and the script reports mismatches instead.

### 1b. Lane bootstrap

```powershell
./scripts/bootstrap.ps1 -CreateGroups
```

Every parameter has a default, so that really is the whole command. It resolves the same storage account name, checks whether the account **and this lane's container** already exist, and runs `New-StateFoundation.ps1` only if something is missing. Then it creates the Entra groups and grants Azure RBAC.

Pass `-WorkspacePrefix my-contoso` to name the workspaces `my-contoso-dev`,
`my-contoso-test` and `my-contoso-prod`, each syncing with the branch of the
same name. Set the same value as `workspace_prefix` in
`infra/workspace/common.auto.tfvars` and `infra/platform/terraform.tfvars`, or
export `TF_VAR_workspace_prefix`, so every later plan derives the same names.
Omitted, the names stay `contoso-fab-ml-<environment>`.

The lane defaults to `ml`, which is why no `-Lane` appears above. In this lane the script deliberately does **not** create an app registration or federated credentials: nothing here authenticates as a service principal, and an unused identity holding Contributor and User Access Administrator on the subscription is a liability rather than an asset. Pass `-CreateServicePrincipal` if you later want to hand this same foundation to a pipeline.

`-CreateGroups` creates `sg-fabric-platform-admins`, `sg-fabric-data-engineers` and `sg-fabric-analysts`, and adds you to the admin group. Omit it if your tenant manages security groups through an identity process; the script then reports which are missing. The groups are shared with the other lane on purpose: they describe people, and the same people administer both.

Record the identifiers it prints at the end.

### Optional: a federated identity for CI

Nothing in this lane needs a service principal. Create one only when you decide to
hand this same state foundation to a pipeline. `./scripts/bootstrap.ps1
-CreateServicePrincipal` does it as part of a lane bootstrap; the equivalent by
hand, with an active Global Administrator role and Owner on the subscription:

```powershell
$repo  = '<owner>/<repository>'
$subId = az account show --query id -o tsv

$appId = az ad app create --display-name sp-fabric-bootstrap `
    --sign-in-audience AzureADMyOrg --query appId -o tsv
az ad sp create --id $appId | Out-Null

# Resolve the app role IDs by name rather than pinning GUIDs
$graph = az ad sp show --id 00000003-0000-0000-c000-000000000000 | ConvertFrom-Json
foreach ($perm in 'Application.ReadWrite.All',
                  'Group.ReadWrite.All',
                  'DelegatedPermissionGrant.ReadWrite.All') {
    $roleId = ($graph.appRoles | Where-Object { $_.value -eq $perm }).id
    az ad app permission add --id $appId --api $graph.appId `
        --api-permissions "$roleId=Role" --only-show-errors
}
az ad app permission admin-consent --id $appId

az role assignment create --assignee $appId --role Owner `
    --scope "/subscriptions/$subId" --only-show-errors | Out-Null

@{
    name      = 'github-bootstrap-main'
    issuer    = 'https://token.actions.githubusercontent.com'
    subject   = "repo:${repo}:ref:refs/heads/main"
    audiences = @('api://AzureADTokenExchange')
} | ConvertTo-Json | Set-Content fic.json
az ad app federated-credential create --id $appId --parameters fic.json
Remove-Item fic.json

"AZURE_BOOTSTRAP_CLIENT_ID = $appId"
```

The credential goes in a file because `--parameters` takes inline JSON that Windows
shells mangle on the way to `az`. If `admin-consent` fails immediately after
`permission add`, wait a minute and re-run only that line; Entra has not finished
propagating the permission request.

There is no client secret, so nothing here expires or needs rotating. The
identity is only useful alongside the GitHub Actions lane, which is described in
[setup-github-actions.md](setup-github-actions.md).

### Update the backend configuration

Set `storage_account_name` in all four files to match what you just created:

* `infra/platform/platform.backend.hcl`
* `infra/workspace/envs/dev.backend.hcl`
* `infra/workspace/envs/test.backend.hcl`
* `infra/workspace/envs/prod.backend.hcl`

## Step 2: Enable Fabric tenant settings

Fabric blocks service principals and GitHub sync by default. Neither Terraform nor `az rest` can change this: the Azure CLI's own app registration requests only `user_impersonation` on the Fabric API, so admin endpoints return `InsufficientScopes` regardless of your roles.

```powershell
./scripts/Enable-FabricGitIntegration.ps1 -IncludeServicePrincipal -WhatIf
./scripts/Enable-FabricGitIntegration.ps1 -IncludeServicePrincipal
```

The script reuses or creates the [fabric-admin-cli](#the-fabric-admin-cli-application) registration with the delegated `Tenant.ReadWrite.All` scope, grants admin consent, signs you in with a device code, and enables the Git and service principal settings scoped to `sg-fabric-platform-admins`.

Allow up to 15 minutes for propagation. A run that fails immediately afterwards is expected.

## Step 3: Configure the environment

```powershell
Copy-Item .env.example .env
```

Fill in the values bootstrap printed, leaving the connection ID blank for now:

```text
FABRIC_LANE=ml
AZURE_TENANT_ID=
AZURE_SUBSCRIPTION_ID=
AZURE_CLIENT_ID=
FABRIC_CICD_SP_OBJECT_ID=
FABRIC_GITHUB_CONNECTION_ID=
```

Every key is optional. Blank values are resolved from your `az login` session, so an untouched copy of `.env.example` is already a working configuration for this lane. Fill a value in only to pin it.

`FABRIC_CICD_SP_OBJECT_ID` stays blank here. Left empty, Terraform treats **you** as the administrator: your object ID receives the Azure role assignments and workspace Admin. That is the whole identity model of this lane.

`.env` is gitignored. None of these are credentials: authentication is your `az login` session locally and OIDC federation in CI.

```powershell
. ./scripts/Load-Env.ps1
```

Dot-source it. Running it normally sets variables in a child scope that disappears immediately.

## Step 4: Apply the platform

**Prerequisite:** [Step 2](#step-2-enable-fabric-tenant-settings) must have
completed and propagated. Terraform cannot create the GitHub connection while
Fabric still blocks service principals and Git sync, and the failure surfaces as
`InsufficientScopes` or `Unauthorized` rather than as anything about tenant
settings.

The defaults in `infra/platform/terraform.tfvars` cover the common case. Change the prefix, region or capacity topology there if you need to, then:

```powershell
$env:TF_VAR_github_pat = '<PAT with Contents read/write on the items repo>'

cd infra\platform
terraform init -reconfigure -backend-config="platform.backend.hcl"
terraform apply -var=create_deployment_pipeline=false
```

The override matters on a first build. The deployment pipeline reads the three
workspaces to assign them to stages, and they do not exist until step 5, so
leaving it on fails the plan at `data.fabric_workspace.stage` with a workspace
not found. Step 5 creates them and then turns the pipeline on.

This creates the resource group, the Fabric capacity, Azure role assignments and the GitHub source control connection, all named `contoso-fab-ml-*`, and writes `platform.tfstate` into the `tfstate-ml` container.

The PAT is assigned to a write-only provider attribute, so Terraform never persists it in state. Rotating it later also requires incrementing `github_pat_version`, because there is nothing in state for Terraform to compare against.

Read the connection GUID back out:

```powershell
terraform output -raw github_connection_id
```

Put it into `.env` as `FABRIC_GITHUB_CONNECTION_ID` and reload:

```powershell
cd ..\..
. ./scripts/Load-Env.ps1
```

## Step 5: Apply the workspaces

No editing required. The workspace name, the capacity name and the Git branch are all derived from prefix, lane and environment, so `envs/<env>.tfvars` holds only genuine per-environment differences.

```powershell
./scripts/Apply-Workspaces.ps1
```

The script pairs `terraform init -reconfigure` with the matching `-var-file` and the lane's state key for each environment, in the order dev, test, prod. Use `-PlanOnly` first if you want to review, and `-AutoApprove` to skip prompts.

If you skipped the connection in step 4, the workspaces still build; Git integration is reported as `git_integration_enabled = false` and engages on the next apply once the GUID is set.

Never run `terraform apply -var environment=prod` by hand. The backend selects the environment; the variable alone only changes the display name, so applying prod variables against the dev backend **renames** the dev workspace instead of creating prod.

### Create the deployment pipeline

Now that the three workspaces exist, apply the platform again without the
override from step 4. This is the pass that creates the pipeline and assigns the
stages:

```powershell
cd infra\platform
terraform apply
cd ..\..
```

The GitHub Actions lane does the same thing as two separate jobs, first and last
in its run.

## Step 6: Assign users to the Fabric workspaces

Terraform grants workspace roles to the three security groups and never to
individuals, so a person gains access by joining a group. Until then the
workspaces are invisible to them, including to you: bootstrap adds the identity
that ran it, which is not necessarily your user account.

Find the group and add yourself:

```powershell
./scripts/Add-MeToFabricGroups.ps1
```

It checks membership before writing, so re-running it after a rebuild is safe.
Add `-All` to join the engineer and analyst groups as well. The equivalent by
hand, or if you prefer to see the calls:

```powershell
$adminGroup = az ad group list --display-name sg-fabric-platform-admins --query '[0].id' -o tsv
az ad group member add --group $adminGroup --member-id (az ad signed-in-user show --query id -o tsv)
```

Add colleagues by object ID, which avoids a directory lookup a restricted account
may not be permitted to make:

```powershell
$userId = az ad user show --id someone@contoso.com --query id -o tsv
az ad group member add --group $adminGroup --member-id $userId
```

Choose the group that matches the access the person needs:

| Group | dev | test | prod |
|-------|-----|------|------|
| `sg-fabric-platform-admins` | Admin | Admin | Viewer |
| `sg-fabric-data-engineers` | Member | Viewer | Viewer |
| `sg-fabric-analysts` | Viewer | Viewer | Viewer |

Verify membership with a direct check, because `az ad group member list` returns
only user members and looks misleadingly empty when a group holds service
principals:

```powershell
az ad group member check --group $adminGroup --member-id $userId --query value -o tsv
```

Fabric caches group membership, so allow a few minutes before the workspaces
appear. Prod is deliberately read-only for humans, so its source-control panel
stays hidden from platform admins even though the Git integration exists. A
break-glass grant belongs in a reviewed pull request through `role_overrides`.

## Step 7: Verify

```powershell
$res = 'https://api.fabric.microsoft.com'
foreach ($e in 'dev','test','prod') {
    $id = terraform -chdir=infra/workspace output -raw workspace_id
    $c = az rest --method GET --url "$res/v1/workspaces/$id/git/connection" --resource $res -o json | ConvertFrom-Json
    $s = az rest --method GET --url "$res/v1/workspaces/$id/git/status" --resource $res -o json | ConvertFrom-Json
    "{0,-5} {1,-26} synced={2}" -f $e, $c.gitConnectionState, ($s.workspaceHead -eq $s.remoteCommitHash)
}
```

Expect `ConnectedAndInitialized` and `synced=True` for each.

## After a teardown and rebuild

Destroying the shared Entra groups invalidates every reference Fabric holds,
because Fabric stores a group's object ID rather than its display name. A rebuilt
group is a new object, so repeat two steps in this order:

1. [Step 6](#step-6-assign-users-to-the-fabric-workspaces): re-add yourself and your colleagues to the recreated groups.
2. [Step 2](#step-2-enable-fabric-tenant-settings): re-run `Enable-FabricGitIntegration.ps1`, which drops the dead group references and rewrites the current ones.

Skipping the second leaves Terraform failing with `Unauthorized` when the Fabric
provider lists connections, because the tenant settings still point at a group
that no longer exists.

To avoid the cycle entirely, leave the three groups out of teardown. They hold no
Azure resources, cost nothing, and are shared with the GitHub Actions lane.

If the estate used a `workspace_prefix`, supply the same value when you rebuild.
A different one builds a second estate beside the first rather than replacing it.

## Day-to-day

```powershell
./scripts/Grant-MyIpToPerimeter.ps1   # after any IP change; no arguments needed
. ./scripts/Load-Env.ps1
./scripts/Apply-Workspaces.ps1
```

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `403 not authorized by network security perimeter` | Your public IP changed. Run `./scripts/Grant-MyIpToPerimeter.ps1` |
| `state blob is already locked` | An interrupted run left an infinite lease. `az storage blob lease break --container-name tfstate --account-name <acct> --blob-name <key> --auth-mode login` |
| `Fabric Capacity State ... NOT in Active state` | Capacity paused. `az fabric capacity resume --capacity-name <name> --resource-group <rg>` |
| `regional quota ... RegionalQuota: 0` | No Fabric quota in that region. Re-run the quota check and pick another |
| `All provided principals must be existing, user or service principals` | Capacity admins reject groups. The platform root expands the admin group to UPNs; do not add a group object ID directly |
| `FeatureNotAvailable` on Git connect | Tenant setting not enabled. Re-run `Enable-FabricGitIntegration.ps1` and wait 15 minutes |
| `WorkspaceAlreadyConnectedToGit` | A failed initialise left the connection behind. `az rest --method POST --url "$res/v1/workspaces/<id>/git/disconnect" --resource $res`, then re-apply |
| `OverrideItemsNotAllowed` | Workspace already contains items. Set `allow_override_items = true` in the environment tfvars |
| `MissingItemDefinitionFiles` | An item folder lacks a valid definition. A `.platform` file alone is not enough for Lakehouse, Report or SemanticModel |
| `unexpected connectivity type` | The `fabric_connections` data source cannot parse a tenant connection. Supply `TF_VAR_github_connection_id` instead |
| `InsufficientScopes` on admin API | The Azure CLI token lacks Fabric admin scopes. Use `Enable-FabricGitIntegration.ps1`, which signs in through its own app |
| `Unauthorized` listing connections during plan | The service principal tenant settings point at a security group that was deleted and rebuilt. Re-run `Enable-FabricGitIntegration.ps1`, which drops the stale references |
| `Insufficient privileges to complete the operation` from `az` | Your directory role is inactive or read-only. Activate it in Privileged Identity Management; Global Reader cannot write |
| Workspaces exist but you cannot see them | You are not in one of the three security groups. See [Step 6](#step-6-assign-users-to-the-fabric-workspaces) |
| Git integration missing on prod only | Expected. Platform admins hold Viewer on prod and the source-control panel is admin-only. Check through the admin portal or the REST API |

## Authoring Fabric items

Do not hand-author item folders. Lakehouse, Report and SemanticModel definitions are strict, and an invalid one fails the whole sync with `MissingItemDefinitionFiles` without naming the offender.

Create items in the **dev workspace**, then commit from Fabric. The workspace writes a valid definition, which then promotes through `test` and `prod` by merging branches.

## Teardown

Use the script. It handles an ordering constraint that is easy to get wrong by hand.

```powershell
./scripts/Remove-Platform.ps1 -Lane ml -IncludeBranches -WhatIf   # preview
./scripts/Remove-Platform.ps1 -Lane ml -IncludeBranches
```

If the lane was built with a prefix, pass the same one. The script matches
resources and branches by name, so without it the sweep finds nothing and
reports a clean teardown over an estate that is still standing:

```powershell
./scripts/Remove-Platform.ps1 -Lane ml -WorkspacePrefix my-contoso -IncludeBranches -WhatIf
```

Without `-Force` it asks you to type the lane name before doing anything. `-WhatIf` never prompts, because it destroys nothing.

The order matters, and two steps are not obvious:

1. **Deployment pipelines first.** Fabric refuses to delete a workspace assigned to a pipeline stage, so a workspace-first teardown fails
2. Resume the capacity if it is paused, or the workspace deletes fail too
3. Workspaces, prod first, so a failure stops before dev
4. Platform, then an orphan sweep by name
5. App registration, branches, groups, state

The orphan sweep is what makes this reliable. `terraform destroy` only removes what state records, so anything deleted out of band, created before a failed apply, or lost with a discarded state file survives and silently blocks the next build. Use `-OrphansOnly` to skip Terraform entirely when state is gone or unreachable.

### Shared resources are opt-in

The state account, the perimeter and the Entra groups are shared with the other lane, so they survive unless you ask for them:

```powershell
./scripts/Remove-Platform.ps1 -Lane ml -IncludeBranches -IncludeGroups -IncludeState
```

Deleting state while the other lane still stands strands it permanently.

### The estate that predates lanes

If you built before the lane split, its names carry no suffix and `-Lane ml` will find nothing. Use:

```powershell
./scripts/Remove-Platform.ps1 -Legacy -IncludeBranches
```

Its prefix also matches both lanes, so this is a whole-estate wipe rather than a surgical one. The script warns about that before proceeding.

### Not removed by any script

Fabric tenant settings, and GitHub Environments with their variables. Neither is reachable with CLI authentication, so both stay as manual steps.
