---
title: Setup with GitHub Actions
description: Bootstrap and operate the Fabric platform through GitHub Actions and federated Azure identities
---

Bootstrap and operate the Microsoft Fabric platform through GitHub Actions using federated Azure service principals and GitHub OIDC.

## Who this is for

An operator setting up the platform so bootstrap and day-to-day infrastructure changes run in GitHub Actions. You need a pre-authorized federated Azure bootstrap service principal, repository administration and a Global or Fabric Administrator for one delegated tenant-settings authorization.

For the fully local alternative see [setup-manual-cli.md](setup-manual-cli.md).

## How this differs from the manual setup

The automated lane uses a pre-authorized Azure service principal as its trust root. The bootstrap workflow authenticates that identity through GitHub OIDC and creates the permanent `sp-fabric-cicd-gh` identity, which also uses repository- and environment-scoped OIDC credentials.

| Concern                              | Manual setup           | GitHub Actions setup      |
|--------------------------------------|------------------------|---------------------------|
| Initial state and tenant bootstrap   | Local scripts          | `bootstrap` workflow      |
| Initial platform and workspace apply | Local Terraform        | `terraform-apply` workflow |
| Ongoing Terraform changes            | Local operator         | Pull request and workflow |
| Permanent authentication             | Azure CLI user session | OIDC service principal    |
| State network access                 | Operator IP allowlist  | Current runner IP rule    |

No Terraform or Azure CLI command runs on your workstation in this path.

## Prerequisites

Work through these before dispatching any workflow. Each one has blocked a real run.

### Azure subscription

| Requirement | Why |
|-------------|-----|
| An Azure subscription you can assign roles in | Bootstrap creates a resource group, a storage account, a network security perimeter and a Fabric capacity |
| Non-zero Fabric capacity-unit quota in the target region | Quota defaults to zero. `centralus` is the working region here; verify before changing it |
| Owner with unrestricted role delegation on that subscription for the bootstrap service principal | It creates resource groups and assigns roles, including `User Access Administrator` for the permanent deployment identity |

Check quota before anything else, because a missing quota fails late:

```powershell
az rest --method GET --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Fabric/locations/<region>/usages?api-version=2023-11-01"
```

### Your own account

You need a directory role with write access. **Global Reader is not enough**, and it
is a common default: it can read everything, so diagnostics succeed and only the
writes fail. Activate the role in Privileged Identity Management before you start,
and remember the activation expires.

| Task | Minimum role |
|------|--------------|
| Grant admin consent for Graph permissions | Privileged Role Administrator or Global Administrator |
| Add members to the security groups | Groups Administrator, User Administrator or Global Administrator |
| Change Fabric tenant settings | Fabric Administrator, Power BI Administrator or Global Administrator |

Confirm what is actually active, rather than what you are eligible for:

```powershell
az rest --method GET `
    --url "https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole" `
    --query "value[].displayName" -o json
```

### Bootstrap service principal

A repository cannot authorize its own first identity, so create this one by hand.
It is used only by `bootstrap.yml`.

1. Register an application in Entra ID and note its client ID.
2. Grant these Microsoft Graph permissions. Each one must be an **Application**
    permission with tenant-wide administrator consent, not a Delegated permission:

    | Permission | Type | Admin consent | Used for |
    |------------|------|---------------|----------|
    | `Application.ReadWrite.All` | Application | Required | Creating the permanent deployment application and service principal |
    | `Group.ReadWrite.All` | Application | Required | Creating the three security groups and managing membership |
    | `DelegatedPermissionGrant.ReadWrite.All` | Application | Required | Consenting the deployment application's Graph permissions |
    | `AppRoleAssignment.ReadWrite.All` | Application | Optional | Granting the deployment application `Directory.Read.All`. Bootstrap continues without it; see the note below before adding it |

3. Assign the bootstrap service principal **Owner** at the target subscription
    scope with **Allow user to assign all roles**. Resource-group access is
    insufficient because bootstrap creates subscription-scoped resources and
    delegates `Storage Blob Data Contributor`, `Contributor` and
    `User Access Administrator` to the permanent deployment identity. The portal
    preselects **Allow user to assign all roles except privileged administrator
    roles**, which writes an ABAC condition that blocks the
    `User Access Administrator` delegation and fails bootstrap. Assigning through
    `az role assignment create` adds no condition.
4. Add the federated credential described under [Trust boundary](#trust-boundary).

All four steps in one pass, with an active Global Administrator role and Owner on
the subscription:

```powershell
$repo = '<owner>/<repository>'
$repoInfo = gh api "repos/$repo" | ConvertFrom-Json
$repositorySubject = "$($repoInfo.owner.login)@$($repoInfo.owner.id)/$($repoInfo.name)@$($repoInfo.id)"
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
    subject   = "repo:${repositorySubject}:ref:refs/heads/main"
    audiences = @('api://AzureADTokenExchange')
} | ConvertTo-Json | Set-Content fic.json
az ad app federated-credential create --id $appId --parameters fic.json
Remove-Item fic.json

"AZURE_BOOTSTRAP_CLIENT_ID = $appId"
```

Before running the workflow, verify that Entra reports each Graph permission as
**Granted for** the tenant and that Azure RBAC resolves the subscription-level
Owner assignment:

```powershell
az ad app permission list --id $appId -o table
az role assignment list --assignee $appId `
    --scope "/subscriptions/$subId" --include-inherited `
    --query "[].{role:roleDefinitionName,scope:scope,condition:condition}" -o table
```

The Owner row must use the subscription scope and report an empty condition. A
condition mentioning `roleAssignments/write` restricts delegation and fails
bootstrap regardless of the role name shown beside it.

To correct a conditional assignment in the Azure portal, open the subscription,
select **Access control (IAM) > Role assignments**, find the bootstrap service
principal, and open **Edit** on its assignment. Under **Conditions**, choose
**Allow user to assign all roles (highly privileged)** and save. Recreating the
assignment from the CLI has the same effect:

```powershell
az role assignment create --assignee-object-id $bootstrapObjectId `
    --assignee-principal-type ServicePrincipal `
    --role Owner --scope "/subscriptions/$subId"
```

If policy forbids unconstrained delegation, keep the condition but extend it to
permit assigning `Storage Blob Data Contributor`, `Contributor` and
`User Access Administrator` to service principals. Run the verification command
again before rerunning bootstrap; the workflow cannot retry past this denial
because the restriction is permanent until the assignment changes.

The credential goes in a file because `--parameters` takes inline JSON that
Windows shells mangle on the way to `az`. If `admin-consent` fails immediately
after `permission add`, wait a minute and re-run only that line; Entra has not
finished propagating the permission request.

Feed the printed client ID, your tenant ID and subscription ID into the
repository variables listed under [Trust boundary](#trust-boundary). If the
repository's owner, name or numeric ID changes, recreate the credential because
the subject match is exact.

`AppRoleAssignment.ReadWrite.All` is optional and best left off. Bootstrap uses it
when present to grant the deployment application `Directory.Read.All`; nothing
depends on that succeeding. It also lets its holder assign any application
permission to any application, which is a large privilege for a CI credential.

### GitHub

| Requirement | Notes |
|-------------|-------|
| Administrator on this repository | Needed to dispatch workflows and set variables |
| A self-hosted Windows x64 runner | Every job declares `runs-on: [self-hosted, Windows, X64]`. Without one registered and online, runs queue indefinitely rather than failing |
| A plan that supports environment protection on private repositories | The workflow creates `platform`, `dev`, `test` and `prod` with reviewers. Without such a plan, bootstrap still creates the environments but logs a warning and leaves them unprotected, so `test` and `prod` deploy without approval |
| An items repository | Holds the Fabric item definitions. Bootstrap creates it and one branch per workspace if missing. `items_owner` sets who owns it, defaulting to a different account than this repository |
| `BOOTSTRAP_GITHUB_TOKEN` | Temporary. Repository administration, Actions and Environments read/write |
| `FABRIC_GITHUB_PAT` | Permanent. Fine-grained token with Contents read/write on the items repository |

### Fabric

You need the **Fabric Administrator** role, or Power BI Administrator, or Global
Administrator. By default this step is manual, because a fresh tenant grants no
service principal access to the admin API. Once that access is granted it can be
automated; see [Fabric administrator authorization](#fabric-administrator-authorization).

Running `scripts/Enable-FabricGitIntegration.ps1` is a prerequisite of
`terraform-apply`, not an optional extra: Fabric blocks service principals and
GitHub sync by default, so the apply cannot succeed before it. `trigger_apply`
defaults to off for that reason; turn it on only when the tenant settings are
already in place.

### The fabric-admin-cli application

`scripts/Enable-FabricGitIntegration.ps1` needs an app registration named
`fabric-admin-cli`. It creates one on first run, so there is nothing to prepare
in advance unless your account cannot consent to Graph permissions.

| Property | Value |
|----------|-------|
| Name | `fabric-admin-cli` |
| Client type | Public client, device code flow. No secret to store or rotate |
| API permission | Power BI Service `Tenant.ReadWrite.All`, **delegated**, admin-consented |
| Sign-in audience | Single tenant |

The Azure CLI's own application requests only `user_impersonation` on the Power BI
Service, so `az rest` cannot reach `/v1/admin/*` no matter which directory roles
you hold. This registration exists solely to obtain a token that carries the admin
scope, and you sign in through it interactively.

Creating it and consenting to the permission needs Privileged Role Administrator
or Global Administrator. If your account cannot consent, ask an administrator to
create the registration once with that delegated permission granted; the script
reuses an existing registration and skips creation. It survives teardown, so this
is a one-time setup per tenant.

## Trust boundary

A repository cannot authorize its own first identity. Configure these repository variables for the pre-authorized bootstrap service principal:

| Variable | Value |
|----------|-------|
| `AZURE_BOOTSTRAP_CLIENT_ID` | Bootstrap application client ID |
| `AZURE_BOOTSTRAP_TENANT_ID` | Entra tenant ID |
| `AZURE_BOOTSTRAP_SUBSCRIPTION_ID` | Target Azure subscription ID |

Add two repository secrets:

| Secret | Lifetime | Required access |
|--------|----------|-----------------|
| `BOOTSTRAP_GITHUB_TOKEN` | Temporary | Repository Administration, Actions and Environments read/write; access to create the items repository |
| `FABRIC_GITHUB_PAT` | Permanent | Fine-grained token with Contents read/write on the items repository |

The bootstrap service principal needs Owner at the target subscription scope with
unrestricted role delegation, because it assigns `User Access Administrator` to
the permanent deployment identity. It also needs these Microsoft Graph
**Application** permissions, each with tenant-wide administrator consent:

* `Application.ReadWrite.All`
* `Group.ReadWrite.All`
* `DelegatedPermissionGrant.ReadWrite.All`

`AppRoleAssignment.ReadWrite.All` is optional. Bootstrap uses it, when present, to
grant the deployment application `Directory.Read.All`. Nothing depends on that
grant succeeding, and the permission also lets its holder assign any application
permission to any application, so leave it off unless you want the convenience.

Create a federated identity credential on the bootstrap application with:

```text
issuer:   https://token.actions.githubusercontent.com
subject: repo:<owner>@<owner-id>/<repository>@<repository-id>:ref:refs/heads/main
audience: api://AzureADTokenExchange
```

The setup command resolves the numeric IDs through the GitHub REST API. The
workflow reads `GITHUB_REPOSITORY_OWNER_ID` and `GITHUB_REPOSITORY_ID`
automatically and uses the same immutable format for the permanent deployment
credentials. Run `bootstrap.yml` from `main`, because the federated subject must
match exactly. Neither Azure service principal has a client secret. Revoke the
bootstrap application's repository federated credential after bootstrap if the
elevated bootstrap path should not remain available.

The permanent deployment application needs no Microsoft Graph permission. Bootstrap resolves the three security groups and publishes their object IDs as repository variables, which the Terraform workflows pass in as inputs. Terraform falls back to looking the groups up by display name only when those variables are absent, and that path does require `Directory.Read.All`.

### Fabric administrator authorization

The tenant-settings APIs accept a signed-in Fabric administrator through a delegated `Tenant.ReadWrite.All` token, which is what `scripts/Enable-FabricGitIntegration.ps1` obtains with a device code by default. See [step 5](#5-enable-the-fabric-tenant-settings-manual).

They also accept a service principal, so the step can be automated. That requires a Fabric administrator to enable **Service principals can access read-only admin APIs** and **Service principals can access admin APIs used for updates** for the bootstrap identity, and the bootstrap app registration must carry no admin-consent-required Fabric permissions, which silently blocks service principal authentication. Scope those two settings to the whole organisation or to a group that is never deleted; scoping them to `sg-fabric-platform-admins` means deleting that group locks the automation out of the API it needs to repair itself.

With that in place, run `bootstrap.yml` with `configure_tenant_settings` enabled and the workflow re-points the settings at the current groups itself. Both APIs are in preview, so the script keeps the device-code path as a fallback.

### GitHub plan requirements

The workflow creates `platform`, `dev`, `test` and `prod` environments. `platform`, `test` and `prod` use the selected reviewer; `prod` accepts deployments only from `main`. Environment protection on a private repository requires a GitHub plan that supports it. On a plan without it, GitHub rejects the protection rules with `HTTP 422`; bootstrap then creates the environments unprotected and continues, so approvals and the `main` restriction are not enforced. Make the repository public, upgrade the plan, or gate promotion another way.

## Run the platform end to end

The order matters. Two of these steps run as GitHub workflows; the rest are manual
and cannot be automated, because only a signed-in administrator can perform them.

| Step | Type | What runs it |
|------|------|--------------|
| 1. Prepare the repository | Manual | You, in the GitHub UI |
| 2. Activate your directory role | Manual | You, in Privileged Identity Management |
| 3. Run bootstrap | **GitHub workflow** | `bootstrap.yml`, dispatched from the Actions tab |
| 4. Assign users to the Fabric workspaces | Manual | You, from a workstation with `az` |
| 5. Enable the Fabric tenant settings | Manual | You, from a workstation with `az` |
| 6. Apply the infrastructure | **GitHub workflow** | `terraform-apply.yml`, dispatched or triggered by bootstrap |
| 7. Clean up the bootstrap path | Manual | You, in the GitHub UI and Entra ID |

### 1. Prepare the repository (manual)

1. Merge [bootstrap.yml](../.github/workflows/bootstrap.yml) into the default branch. The federated subject pins the credential to `main`, so bootstrap must run from there.
2. Under **Settings > Secrets and variables > Actions**, add the three `AZURE_BOOTSTRAP_*` variables and the two secrets.

### 2. Activate your directory role (manual)

Activate Global Administrator, or the narrower roles listed under
[Your own account](#your-own-account), in Privileged Identity Management. Steps 4
and 5 fail with `Insufficient privileges` without it.

### 3. Run bootstrap (GitHub workflow)

Open **Actions > bootstrap > Run workflow** and set the state account, region,
items repository and environment reviewer. Leave `trigger_apply` off on a first
build: the apply cannot succeed until step 5 has enabled the Fabric tenant
settings, and bootstrap has no way to do that for you. Turning it on is a
convenience for a rebuild, where the settings already exist.

`items_owner` is the GitHub account or organisation that owns the items
repository. It does not have to be the owner of this repository, and often is
not. Clear it to fall back to this repository's owner. Only the owner is
configurable, not the host: Fabric's GitHub source control connection is
github.com only, so a GitHub Enterprise Server URL cannot be used.

`workspace_prefix` is optional and names the estate. Enter `my-contoso` and the
workspaces become `my-contoso-dev`, `my-contoso-test` and `my-contoso-prod`, each
syncing with the branch of the same name, which bootstrap creates. Left empty,
the names stay `contoso-fab-gh-<environment>` on `gh-<environment>` branches.

The value is published as the `FABRIC_WORKSPACE_PREFIX` repository variable and
read by every later plan, apply and destroy. Changing it after the first apply
renames every workspace, and Fabric implements a rename as destroy and recreate,
so the items in them are lost. Pick it before step 6, not after.

The workflow is idempotent: re-running it adopts existing state, groups,
applications, repositories, branches, environments and variables.

Two inputs are off or defaulted for a first build. `configure_tenant_settings`
re-points the Fabric tenant settings at the current groups, which works only once
the admin-API access described under
[Fabric administrator authorization](#fabric-administrator-authorization) exists.
`propagation_wait_minutes` defaults to 12 and pauses before the dispatch so the
tenant settings can propagate; it applies only when `trigger_apply` is on, and 0
skips it.

### 4. Assign users to the Fabric workspaces (manual)

Terraform grants workspace roles to the three security groups and never to
individuals, so a person gains access by joining a group. Nobody sees a workspace
until then, and bootstrap adds only the identity it runs as. This is why a
freshly built platform looks empty to the person who built it.

Find the group and add yourself:

```powershell
az login
./scripts/Add-MeToFabricGroups.ps1
```

It checks membership before writing, so re-running it after a rebuild is safe.
Add `-All` to join the engineer and analyst groups as well. The equivalent by
hand:

```powershell
$adminGroup = az ad group list --display-name sg-fabric-platform-admins --query '[0].id' -o tsv
az ad group member add --group $adminGroup --member-id (az ad signed-in-user show --query id -o tsv)
```

Add colleagues by object ID, which avoids a directory lookup that a restricted
account may not be allowed to perform:

```powershell
$userId = az ad user show --id someone@contoso.com --query id -o tsv
az ad group member add --group $adminGroup --member-id $userId
```

Pick the group that matches the access the person needs:

| Group | dev | test | prod |
|-------|-----|------|------|
| `sg-fabric-platform-admins` | Admin | Admin | Viewer |
| `sg-fabric-data-engineers` | Member | Viewer | Viewer |
| `sg-fabric-analysts` | Viewer | Viewer | Viewer |

Verify membership, because `az ad group member list` omits service principals and
can look misleadingly empty:

```powershell
az ad group member check --group $adminGroup --member-id $userId --query value -o tsv
```

Fabric caches group membership, so allow a few minutes before the workspaces
appear. Prod is deliberately read-only for humans: a break-glass grant belongs in
a reviewed pull request through `role_overrides`, not a portal click. Because
platform admins hold Viewer there, prod's Git integration panel is not visible
even though the integration exists.

### 5. Enable the Fabric tenant settings (manual)

```powershell
./scripts/Enable-FabricGitIntegration.ps1 -IncludeServicePrincipal
```

The script reuses or creates the [fabric-admin-cli](#the-fabric-admin-cli-application)
registration, signs you in with a device code, finds the Git integration settings
in the live list and scopes them to `sg-fabric-platform-admins`. Use `-List` first
to see the current state without changing anything, and `-WhatIf` to preview the
updates.

Allow up to 15 minutes for the change to propagate before running Terraform.

### 6. Apply the infrastructure (GitHub workflow)

**Prerequisite:** step 5 must have completed and propagated. `terraform-apply`
fails at the Fabric provider with `InsufficientScopes` or `Unauthorized` while
service principals are still blocked from the Fabric API, and no amount of
re-running the workflow fixes it.

Dispatch **terraform-apply** from the Actions tab. Approve the protected
`platform`, `test` and `prod` environments when prompted. Bootstrap only
dispatches it for you when `trigger_apply` was on.

### 7. Clean up the bootstrap path (manual)

Remove `BOOTSTRAP_GITHUB_TOKEN` and revoke the bootstrap application's federated
credential once the platform is running. Both exist only to establish trust.

## After a teardown and rebuild

Destroying the shared Entra groups invalidates every reference Fabric holds,
because Fabric stores a group's object ID rather than its name. A rebuilt group is
a new object, so repeat steps 4 and 5 above:

1. Re-add yourself and your colleagues to the recreated groups with `./scripts/Add-MeToFabricGroups.ps1`.
2. Re-run `Enable-FabricGitIntegration.ps1 -IncludeServicePrincipal`, which drops the dead group references and rewrites the current ones.

Skipping either leaves Terraform failing with `Unauthorized` when the Fabric
provider lists connections, because the tenant settings still point at a group
that no longer exists.

To avoid the whole cycle, leave the three groups out of teardown. They hold no
Azure resources and are shared with the manual lane.

If the estate used a `workspace_prefix`, enter the same value when you re-run
bootstrap. A different one builds a second estate beside the first rather than
replacing it.

## What bootstrap creates

| Layer | Result |
|-------|--------|
| State | Storage account, `tfstate-gh` container, network security perimeter and deletion lock |
| Identity | `sp-fabric-cicd-gh`, six federated credentials and Azure RBAC |
| Entra ID | Platform admin, data engineer and analyst groups when absent |
| Source | Items repository with one branch per workspace, `gh-{dev,test,prod}` unless `workspace_prefix` was set |
| GitHub | Four environments, protection rules where the plan allows them, and repository/environment variables |
| Fabric | Tenant settings after delegated approval |
| Deployment | Dispatch of `terraform-apply.yml`, only when `trigger_apply` is on |

GitHub-hosted runners add their current public IP to the state perimeter before `terraform init`. The IP rule grants network reachability only; Entra RBAC is still required to read state. Sequential apply jobs remove stale IP rules as they move through the environments.

## Deployment flow

[terraform-apply.yml](../.github/workflows/terraform-apply.yml) walks the environments in order:

```text
apply-platform -> apply-dev -> apply-test -> apply-prod -> apply-deployment-pipeline
```

Each job is bound to its GitHub Environment, so `test` and `prod` pause for approval wherever protection rules were applied. Each has a `concurrency` group, so two runs cannot apply against the same state file simultaneously.

The first platform pass creates the capacity and Fabric GitHub connection with deployment-pipeline creation temporarily disabled. The workspace jobs consume the connection GUID from that job. After all three workspaces exist, the final platform pass creates and assigns the deployment pipeline.

Both Terraform workflows set `TF_VAR_lane: gh` and `STATE_CONTAINER: tfstate-gh` at workflow scope. Backend account and resource-group values come from variables created by bootstrap, so committed backend files do not need to be rewritten.

After bootstrap, every infrastructure change follows a pull request. [terraform-plan.yml](../.github/workflows/terraform-plan.yml) runs `fmt`, `validate`, `tflint` and `checkov`, plans all four Terraform roots and posts each plan as a pull-request comment.

## What the workflows do not do

**Item deployment.** Promotion is Git-based: each workspace syncs its own branch in the items repository, and promotion is a merge from `dev` to `test` to `prod` followed by an update-from-Git. The workflows manage infrastructure only.

**Stage deployment.** Terraform creates the deployment pipeline and assigns workspaces to stages, but deploying between stages is an operation rather than a resource. Trigger it through the REST API or the portal.

## Verify a CI run

Open the merged commit's `terraform-apply` run under the repository's **Actions** tab. Confirm all five jobs succeeded and that the protected environments recorded the expected approvals. If bootstrap warned that the plan does not support protection rules, the environments exist without reviewers and the jobs run straight through.

In the Fabric portal, confirm that the `contoso-fab-gh-dev`, `contoso-fab-gh-test` and `contoso-fab-gh-prod` workspaces exist and each reports `ConnectedAndInitialized` under Git integration. Confirm that `contoso-fab-gh-release` contains all three assigned stages.

If bootstrap ran with a `workspace_prefix`, substitute it: `my-contoso-dev` and so on, with the pipeline at `my-contoso-release`.

## Troubleshooting CI

| Symptom | Cause and fix |
| --- | --- |
| `403 not authorized by network security perimeter` at init | The runner access step failed or has not propagated. Confirm the deployment principal can update the perimeter and that both `TF_STATE_*` variables are set |
| `No value for required variable` | A GitHub variable is missing. Re-run bootstrap to restore repository and environment variables |
| `Repository secret FABRIC_GITHUB_PAT is required` | Create the repository secret with access to the items repository |
| `AADSTS70021` or `AADSTS700213`: No matching federated identity record | Compare the assertion subject in the error with the Entra credential character for character. For bootstrap, use the immutable owner and repository ID form under [Trust boundary](#trust-boundary); for later workflows, check the branch or environment suffix |
| `Request contains a property with duplicate values` while adding credentials | Entra has not propagated the previous federated credential write. The bootstrap retries this condition with bounded backoff |
| `Insufficient privileges` at `az ad app list` during bootstrap | Subscription Owner does not grant Microsoft Graph access. Confirm `AZURE_BOOTSTRAP_CLIENT_ID` identifies the app you configured, then grant that app the `Application.ReadWrite.All` **Application** permission with tenant-wide administrator consent. Under **API permissions**, its status must be **Granted for** the tenant |
| `Failed to create the environment protection rule` with `HTTP 422` | The repository's plan does not support environment protection on private repositories. Bootstrap warns and creates the environments unprotected, so no run fails. To restore approvals, upgrade the plan or make the repository public, then re-run bootstrap |
| `AuthorizationFailed` with `ABAC condition that is not fulfilled` while assigning a role | The bootstrap identity holds a constrained role-delegation condition, usually the portal default **Allow user to assign all roles except privileged administrator roles**, which excludes `User Access Administrator`. Edit its subscription assignment to **Allow user to assign all roles**, or extend the condition to cover `Storage Blob Data Contributor`, `Contributor` and `User Access Administrator`. Refreshing credentials does not help, and the workflow does not retry because the denial is permanent until the assignment changes |
| `InsufficientScopes` calling Fabric | Tenant settings for service principals are not enabled. Run [step 5](#5-enable-the-fabric-tenant-settings-manual) |
| `Unauthorized` on `fabric_connection` during plan | The service principal tenant settings point at a security group that was deleted and rebuilt. Re-run [step 5](#5-enable-the-fabric-tenant-settings-manual), which drops the stale references |
| `Insufficient privileges to complete the operation` from a manual `az` command | Your interactive directory role is read-only. Activate Global Administrator or the narrower role in Privileged Identity Management |
| `/me request is only valid with delegated authentication flow` | A service principal cannot resolve a user. Pass an object ID rather than a UPN |
| Workspaces exist but you cannot see them | You are not in one of the three security groups. Run `./scripts/Add-MeToFabricGroups.ps1`, then allow a few minutes for Fabric to notice. See [step 4](#4-assign-users-to-the-fabric-workspaces-manual) |
| Git integration absent on prod only | Expected. Platform admins hold Viewer on prod, and the source-control panel is admin-only. Verify through the admin portal or the REST API |
| `Fabric Capacity State` on test or prod | Capacity paused. `az fabric capacity resume`. Dev passes because `skip_capacity_state_validation = true` |
| `WorkspaceAlreadyConnectedToGit` | A previous failed run left the connection. Disconnect via the API, then re-run |
| Job waits indefinitely | Environment approval pending, or a `concurrency` group is held by an earlier run |
| `state blob is already locked` | A cancelled run left an infinite lease. Break it with `az storage blob lease break` |

## Rotating the service principal

Federated credentials do not expire, but if you replace the app registration:

1. Restore the two temporary bootstrap secrets.
2. Remove the old `sp-fabric-cicd-gh` application after recording the change.
3. Re-run the bootstrap workflow to recreate OIDC trust and variables.
4. Let the dispatched apply restore capacity and workspace administration.
5. Remove the temporary bootstrap secrets again.

Capacity admin membership is a snapshot taken at apply time, not a live group binding. A new principal is not an admin until Terraform runs again.

## Teardown

Run the destroy locally rather than through CI, so an approval gate cannot leave it half-finished.

```powershell
./scripts/Remove-Platform.ps1 -Lane gh -IncludeBranches -WhatIf   # preview
./scripts/Remove-Platform.ps1 -Lane gh -IncludeBranches
```

Add `-WorkspacePrefix my-contoso` if bootstrap ran with one. The script matches
by name, so without it the sweep finds nothing and reports a clean teardown over
an estate that is still standing.

It deletes the deployment pipeline before the workspaces, because Fabric refuses to delete a workspace assigned to a pipeline stage. It then sweeps for anything named `contoso-fab-gh-*` that Terraform lost track of, and removes `sp-fabric-cicd-gh` with its federated credentials.

By hand, if you need to:

```powershell
. ./scripts/Load-Env.ps1 -Lane gh
cd infra\workspace
foreach ($e in 'prod','test','dev') {
    terraform init -reconfigure `
        -backend-config="envs/$e.backend.hcl" `
        -backend-config="container_name=tfstate-gh"
    terraform destroy -var-file="envs/$e.tfvars"
}

cd ..\platform
terraform init -reconfigure `
    -backend-config="platform.backend.hcl" `
    -backend-config="container_name=tfstate-gh"
terraform destroy
```

Then the bootstrap resources, which Terraform does not manage. Only remove the state account and perimeter if the manual lane is also gone: both lanes share them.

```powershell
az ad app delete --id <client id>

# Shared with the ml lane. Skip unless that lane is destroyed too.
./scripts/Remove-Platform.ps1 -Lane gh -IncludeState -Force
```

Finally remove the four GitHub Environments and their variables. Tenant settings and Entra security groups are deliberately left in place.
