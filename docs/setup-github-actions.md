---
title: Setup with GitHub Actions
description: Bootstrap and operate the Microsoft Fabric platform through GitHub Actions using federated Azure service principals and GitHub OIDC.
author: Fabric Platform Team
ms.date: 2026-08-20
ms.topic: how-to
keywords:
  - microsoft fabric
  - terraform
  - github actions
  - oidc
estimated_reading_time: 18
---

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

The bootstrap service principal needs Owner on the target subscription. It also needs these Microsoft Graph application permissions with administrator consent:

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
subject:  repo:<owner>/<repository>:ref:refs/heads/main
audience: api://AzureADTokenExchange
```

Use GitHub's immutable subject format when it is enabled for the repository:

```text
subject: repo:<owner>@<owner-id>/<repository>@<repository-id>:ref:refs/heads/main
```

The workflow reads `GITHUB_REPOSITORY_OWNER_ID` and `GITHUB_REPOSITORY_ID` automatically and uses the same immutable format for the permanent deployment credentials. Run `bootstrap.yml` from `main`, because the federated subject must match exactly. Neither Azure service principal has a client secret. Revoke the bootstrap application's repository federated credential after bootstrap if the elevated bootstrap path should not remain available.

### Fabric administrator authorization

Fabric tenant-setting administration requires a delegated `Tenant.ReadWrite.All` token. Application credentials cannot remove this delegated consent boundary. When `configure_tenant_settings` is selected, monitor the **Enable Fabric tenant settings** step, open the displayed device-login URL and authorize it as a Global, Fabric or Power BI Administrator.

This is the only interactive action. If the required Git and service-principal tenant settings are already enabled, clear `configure_tenant_settings` and the bootstrap is unattended.

### GitHub plan requirements

The workflow creates `platform`, `dev`, `test` and `prod` environments. `platform`, `test` and `prod` use the selected reviewer; `prod` accepts deployments only from `main`. Environment protection on a private repository requires a GitHub plan that supports it.

## Enable the Fabric tenant settings

This is a manual step. Fabric's admin API accepts only a signed-in administrator
here, so the workflow leaves `configure_tenant_settings` off and CI never runs
it. From a workstation, signed in as a Fabric administrator:

```powershell
az login
./scripts/Enable-FabricGitIntegration.ps1 -IncludeServicePrincipal
```

The script signs in with a device code, finds the Git integration settings in the
live list and scopes them to `sg-fabric-platform-admins`. Allow up to 15 minutes
for the change to reach the workspaces.

Repeat it whenever the security groups are recreated. Fabric stores the group
object ID, not its name, so a rebuilt group leaves a stale reference behind and
the settings stop applying. The script drops references to groups that no longer
exist and rewrites the current ones.

## Run bootstrap

1. Merge [bootstrap.yml](../.github/workflows/bootstrap.yml) into the default branch.
2. Add the three bootstrap variables and two secrets under **Settings > Secrets and variables > Actions**.
3. Open **Actions > bootstrap > Run workflow**.
4. Choose the state account, region, items repository and environment reviewer.
5. Enable the Fabric tenant settings manually, as described above.
6. Approve the protected jobs in the dispatched `terraform-apply` run.
7. Remove `BOOTSTRAP_GITHUB_TOKEN` and revoke the bootstrap federation if it is no longer needed.

The workflow is idempotent. Re-running it adopts existing state, groups, applications, repositories, branches, environments and variables.

The permanent deployment application needs no Microsoft Graph permission.
Bootstrap resolves the three security groups and publishes their object IDs as
repository variables, which the Terraform workflows pass in as inputs. Terraform
falls back to looking the groups up by display name only when those variables are
absent, and that path does require `Directory.Read.All`.

## What bootstrap creates

| Layer | Result |
|-------|--------|
| State | Storage account, `tfstate-gh` container, network security perimeter and deletion lock |
| Identity | `sp-fabric-cicd-gh`, six federated credentials and Azure RBAC |
| Entra ID | Platform admin, data engineer and analyst groups when absent |
| Source | Items repository with `gh-dev`, `gh-test` and `gh-prod` branches |
| GitHub | Four environments, protection rules and repository/environment variables |
| Fabric | Tenant settings after delegated approval |
| Deployment | Dispatch of `terraform-apply.yml` |

GitHub-hosted runners add their current public IP to the state perimeter before `terraform init`. The IP rule grants network reachability only; Entra RBAC is still required to read state. Sequential apply jobs remove stale IP rules as they move through the environments.

## Deployment flow

[terraform-apply.yml](../.github/workflows/terraform-apply.yml) walks the environments in order:

```text
apply-platform -> apply-dev -> apply-test -> apply-prod -> apply-deployment-pipeline
```

Each job is bound to its GitHub Environment, so `test` and `prod` pause for approval. Each has a `concurrency` group, so two runs cannot apply against the same state file simultaneously.

The first platform pass creates the capacity and Fabric GitHub connection with deployment-pipeline creation temporarily disabled. The workspace jobs consume the connection GUID from that job. After all three workspaces exist, the final platform pass creates and assigns the deployment pipeline.

Both Terraform workflows set `TF_VAR_lane: gh` and `STATE_CONTAINER: tfstate-gh` at workflow scope. Backend account and resource-group values come from variables created by bootstrap, so committed backend files do not need to be rewritten.

After bootstrap, every infrastructure change follows a pull request. [terraform-plan.yml](../.github/workflows/terraform-plan.yml) runs `fmt`, `validate`, `tflint` and `checkov`, plans all four Terraform roots and posts each plan as a pull-request comment.

## What the workflows do not do

**Item deployment.** Promotion is Git-based: each workspace syncs its own branch in the items repository, and promotion is a merge from `dev` to `test` to `prod` followed by an update-from-Git. The workflows manage infrastructure only.

**Stage deployment.** Terraform creates the deployment pipeline and assigns workspaces to stages, but deploying between stages is an operation rather than a resource. Trigger it through the REST API or the portal.

## Verify a CI run

Open the merged commit's `terraform-apply` run under the repository's **Actions** tab. Confirm all five jobs succeeded and that the protected environments recorded the expected approvals.

In the Fabric portal, confirm that the `contoso-fab-gh-dev`, `contoso-fab-gh-test` and `contoso-fab-gh-prod` workspaces exist and each reports `ConnectedAndInitialized` under Git integration. Confirm that `contoso-fab-gh-release` contains all three assigned stages.

## Troubleshooting CI

| Symptom | Cause and fix |
| --- | --- |
| `403 not authorized by network security perimeter` at init | The runner access step failed or has not propagated. Confirm the deployment principal can update the perimeter and that both `TF_STATE_*` variables are set |
| `No value for required variable` | A GitHub variable is missing. Re-run bootstrap to restore repository and environment variables |
| `Repository secret FABRIC_GITHUB_PAT is required` | Create the repository secret with access to the items repository |
| `AADSTS70021: No matching federated identity record` | The federated credential subject does not match. Check the environment name in the workflow against the credential |
| `Request contains a property with duplicate values` while adding credentials | Entra has not propagated the previous federated credential write. The bootstrap retries this condition with bounded backoff |
| `InsufficientScopes` calling Fabric | Tenant settings for service principals are not enabled. Re-run bootstrap with `configure_tenant_settings` selected |
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
