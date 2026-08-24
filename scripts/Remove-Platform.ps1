<#
.SYNOPSIS
    Destroys everything one lane created. Irreversible.

.DESCRIPTION
    Removes resources in the only order that works:

      1. Fabric workspaces  (prod, test, dev - a failure stops before dev)
      2. Platform           (deployment pipeline, connection, capacity, RBAC, RG)
      3. Orphan sweep       (anything named for this lane that Terraform lost)
      4. App registration   (gh lane only)
      5. Items repo branches
      6. Entra groups       (shared; opt in)
      7. Terraform state    (shared; opt in, and last, because Terraform needs
                             it to know what to destroy)

    Only resources carrying this lane's suffix are touched. The other lane, the
    state account and the perimeter survive unless you opt in explicitly.

    The orphan sweep is the part that matters in practice. `terraform destroy`
    only removes what is recorded in state, so anything deleted out of band,
    created before a failed apply, or lost with a discarded state file stays
    behind and silently blocks the next build. The sweep finds those by name.

.EXAMPLE
    # See what would go, without touching anything.
    ./scripts/Remove-Platform.ps1 -WhatIf

.EXAMPLE
    # Destroy the manual lane, keeping shared state and groups.
    ./scripts/Remove-Platform.ps1

.EXAMPLE
    # Destroy the CI lane completely, including its app registration.
    ./scripts/Remove-Platform.ps1 -Lane gh -IncludeBranches

.EXAMPLE
    # Remove the estate built before lanes existed (contoso-fab-dev, rg-contoso-fab-fabric,
    # platform.tfstate). Run this before rebuilding into lanes.
    ./scripts/Remove-Platform.ps1 -Legacy -IncludeBranches

.EXAMPLE
    # Clean slate: both lanes gone, then the shared foundation.
    ./scripts/Remove-Platform.ps1 -Lane gh -IncludeBranches -Force
    ./scripts/Remove-Platform.ps1 -Lane ml -IncludeBranches -IncludeGroups -IncludeState -Force
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('gh', 'ml', '')] [string] $Lane = '',

    [string] $Prefix = 'contoso-fab',

    # The value the lane was bootstrapped with. Replaces the derived
    # <prefix>-<lane> for resource names, branch names and the Terraform
    # variable, so the destroy plan looks up the objects that actually exist.
    [ValidatePattern('^$|^[a-z][a-z0-9-]{2,30}$', Options = 'None')]
    [string] $WorkspacePrefix = '',

    [string] $SubscriptionId,

    # Target the pre-lane estate: names without a lane suffix, the original
    # single 'tfstate' container, and sp-fabric-cicd rather than
    # sp-fabric-cicd-<lane>.
    #
    # Note that the resulting name prefix also matches both lanes, so this is a
    # whole-estate wipe rather than a surgical one.
    [switch] $Legacy,

    [string] $ContainerPrefix = 'tfstate',

    # Overrides the derived prefix outright, for an estate that follows neither
    # convention.
    [string] $NamePrefix = '',

    # Defaults to sp-fabric-cicd-<lane>.
    [string] $AppName = '',

    [string] $StateResourceGroup = 'rg-terraform-state',

    # Overrides the account named in the committed backend files, which carry the
    # manual lane's value. Empty keeps whatever the backend file says.
    [string] $StateStorageAccount = '',

    [string] $StateLockName = 'terraform-state-protect',

    [string] $ItemsRepoPath = '',
    [string] $ItemsRemote = 'origin',

    [string] $AdminGroup = 'sg-fabric-platform-admins',
    [string] $EngineerGroup = 'sg-fabric-data-engineers',
    [string] $AnalystGroup = 'sg-fabric-analysts',

    [ValidateSet('dev', 'test', 'prod')]
    [string[]] $Environments = @('prod', 'test', 'dev'),

    # Skip Terraform entirely and delete by name. For when state is gone,
    # corrupt, or was never yours.
    [switch] $OrphansOnly,

    [switch] $IncludeBranches,
    [switch] $IncludeGroups,
    [switch] $IncludeState,
    [switch] $KeepServicePrincipal,

    # Skip the typed confirmation. -WhatIf still wins over this.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script inspects $LASTEXITCODE to tolerate "already gone" responses, so
# PowerShell 7.4+ must not turn a non-zero native exit into a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$FabricApi = 'https://api.fabric.microsoft.com'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$RemovePlatformCmdlet = $PSCmdlet

# The lane suffix appears in three places that must agree: resource names, the
# state container and the app registration. -Legacy drops it from all three.
# -WorkspacePrefix replaces the name and branch stems but not the container or
# the app registration, which stay lane-scoped.
$StateContainer = if ($Legacy) { $ContainerPrefix } else { "$ContainerPrefix-$Lane" }
if (-not $NamePrefix) {
    $NamePrefix = if ($WorkspacePrefix) { $WorkspacePrefix } elseif ($Legacy) { $Prefix } else { "$Prefix-$Lane" }
}
if (-not $AppName) { $AppName = if ($Legacy) { 'sp-fabric-cicd' } else { "sp-fabric-cicd-$Lane" } }
$BranchPrefix = if ($WorkspacePrefix) { "$WorkspacePrefix-" } elseif ($Legacy) { '' } else { "$Lane-" }

# Terraform must derive the same names the estate was built with, or the
# fabric_capacity data source looks up a capacity that no longer exists and the
# destroy plan fails before removing anything.
$TfLane = if ($Legacy) { '' } else { $Lane }

$script:Removed = [System.Collections.Generic.List[object]]::new()
$script:Failed = [System.Collections.Generic.List[object]]::new()

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-AzQuiet {
    param([Parameter(Mandatory)][string[]] $Arguments)
    & az @Arguments *>&1 | Out-Null
    return $LASTEXITCODE
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $raw = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Record {
    param([string] $Kind, [string] $Name, [string] $Status)
    $script:Removed.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Status = $Status })
}

function Record-Failure {
    param([string] $Kind, [string] $Name, [string] $Reason)
    $script:Failed.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Reason = $Reason })
    Write-Host "    FAILED  $Kind '$Name': $Reason" -ForegroundColor Red
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
$account = Invoke-AzJson @('account', 'show', '-o', 'json')
if (-not $account) { throw 'Not signed in. Run `az login` first.' }

if (-not $SubscriptionId) { $SubscriptionId = $account.id }
Write-Host "Subscription : $($account.name) ($SubscriptionId)"
Write-Host "Tenant       : $($account.tenantId)"
Write-Host "Lane         : $(if ($Legacy) { 'legacy (pre-lane estate)' } else { $Lane })"
Write-Host "Name prefix  : $NamePrefix"

$scope = @()
if (-not $OrphansOnly) { $scope += 'Fabric workspaces and all item content in them (OneLake data is NOT recoverable)' }
$scope += "Fabric capacity, deployment pipeline and connection named $NamePrefix-*"
$scope += "Resource group rg-$NamePrefix-fabric"
if (-not $KeepServicePrincipal) { $scope += "App registration $AppName" }
if ($IncludeBranches) { $scope += "Branches $($BranchPrefix)dev, $($BranchPrefix)test, $($BranchPrefix)prod in the items repository" }
if ($IncludeGroups) { $scope += "SHARED Entra groups: $AdminGroup, $EngineerGroup, $AnalystGroup" }
if ($IncludeState) { $scope += "SHARED Terraform state: resource group $StateResourceGroup (destroys the OTHER lane's state too)" }

Write-Host ''
Write-Host 'The following will be destroyed:' -ForegroundColor Yellow
$scope | ForEach-Object { Write-Host "  - $_" }

if ($Legacy) {
    Write-Host ''
    Write-Host "WARNING: '$NamePrefix-' also matches $Prefix-gh-* and $Prefix-ml-*." -ForegroundColor Red
    Write-Host '         The orphan sweep will take both lanes with it.' -ForegroundColor Red
}

if ($IncludeState) {
    Write-Host ''
    Write-Host 'WARNING: the state account and perimeter are shared by both lanes.' -ForegroundColor Red
    Write-Host '         Deleting them strands any lane you have not already destroyed.' -ForegroundColor Red
}

if (-not $Force -and -not $WhatIfPreference) {
    Write-Host ''
    $expected = if ($Legacy) { 'legacy' } else { $Lane }
    $answer = Read-Host "Type '$expected' to proceed"
    if ($answer -ne $expected) { Write-Host 'Aborted.'; return }
}

# -----------------------------------------------------------------------------
# 1. Terraform destroy
# -----------------------------------------------------------------------------
function Invoke-TerraformDestroy {
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $BackendConfig,
        [Parameter(Mandatory)][string] $StateKey,
        [string] $VarFile,
        [string[]] $VarOverrides = @(),
        [Parameter(Mandatory)][string] $Label
    )

    if (-not $RemovePlatformCmdlet.ShouldProcess($Label, 'terraform destroy')) { return $true }

    Push-Location (Join-Path $RepoRoot $Directory)
    try {
        $initArgs = @(
            'init', '-reconfigure', '-no-color'
            "-backend-config=$BackendConfig"
            "-backend-config=resource_group_name=$StateResourceGroup"
            "-backend-config=container_name=$StateContainer"
            "-backend-config=key=$StateKey"
        )
        if ($StateStorageAccount) {
            $initArgs += "-backend-config=storage_account_name=$StateStorageAccount"
        }

        & terraform @initArgs
        if ($LASTEXITCODE -ne 0) {
            Record-Failure -Kind 'terraform init' -Name $Label -Reason 'init failed; state may be unreachable behind the perimeter (run scripts/Grant-MyIpToPerimeter.ps1)'
            return $false
        }

        $tfArgs = @('destroy', '-auto-approve', '-no-color', "-var=lane=$TfLane", "-var=workspace_prefix=$WorkspacePrefix")
        if ($VarFile) { $tfArgs += "-var-file=$VarFile" }
        foreach ($assignment in $VarOverrides) { $tfArgs += "-var=$assignment" }
        & terraform @tfArgs
        if ($LASTEXITCODE -ne 0) {
            Record-Failure -Kind 'terraform destroy' -Name $Label -Reason 'destroy failed; the orphan sweep below will try to finish the job'
            return $false
        }

        Record -Kind 'terraform' -Name $Label -Status 'destroyed'
        return $true
    }
    finally {
        Pop-Location
    }
}

# Fabric refuses to delete a workspace that is assigned to a deployment pipeline
# stage, so the pipeline has to go first. Terraform would do the opposite: the
# pipeline lives in the platform root, which is destroyed after the workspaces.
function Remove-DeploymentPipelines {
    $list = Invoke-AzJson @('rest', '--method', 'GET', '--url', "$FabricApi/v1/deploymentPipelines", '--resource', $FabricApi, '-o', 'json')
    if (-not $list -or $list.PSObject.Properties.Name -notcontains 'value') {
        Write-Host '    could not list deployment pipelines (insufficient permission, or none exist)'
        return
    }

    $targets = @($list.value | Where-Object {
            $_.PSObject.Properties.Name -contains 'displayName' -and
            $_.displayName -and
            $_.displayName.StartsWith("$NamePrefix-")
        })
    if (-not $targets) {
        Write-Host '    none found'
        return
    }

    foreach ($item in $targets) {
        if (-not $RemovePlatformCmdlet.ShouldProcess($item.displayName, 'delete deployment pipeline')) { continue }
        if ((Invoke-AzQuiet @('rest', '--method', 'DELETE', '--url', "$FabricApi/v1/deploymentPipelines/$($item.id)", '--resource', $FabricApi)) -eq 0) {
            Write-Host "    deleted '$($item.displayName)'"
            Record -Kind 'deployment pipeline' -Name $item.displayName -Status 'deleted'
        }
        else {
            Record-Failure -Kind 'deployment pipeline' -Name $item.displayName -Reason 'delete rejected; workspaces assigned to it cannot be deleted until it is gone'
        }
    }
}

if ($OrphansOnly) {
    Write-Step 'Skipping Terraform (-OrphansOnly): deleting by name instead'
    Write-Step 'Deleting deployment pipelines (they block workspace deletion)'
    Remove-DeploymentPipelines
}
else {
    # A destroy plan still reads every data source whose inputs are static, so an
    # already-deleted Entra group aborts it before anything is removed. Supplying
    # IDs switches those lookups off; the values are never used, because destroy
    # works from state. TF_VAR_ is deliberate: unlike -var, a root that does not
    # declare the variable ignores it instead of failing.
    $placeholderGuid = '00000000-0000-0000-0000-000000000000'
    if (-not $env:TF_VAR_platform_admin_group_object_id) {
        $env:TF_VAR_platform_admin_group_object_id = $placeholderGuid
    }
    if (-not $env:TF_VAR_group_object_ids) {
        $env:TF_VAR_group_object_ids = @{
            platform_admins = $placeholderGuid
            data_engineers  = $placeholderGuid
            analysts        = $placeholderGuid
        } | ConvertTo-Json -Compress
    }

    Write-Step 'Deleting deployment pipelines (they block workspace deletion)'
    Remove-DeploymentPipelines

    # A suspended capacity refuses workspace operations, so a paused capacity
    # makes the workspace destroy fail rather than skip.
    Write-Step 'Resuming the capacity if it is paused'
    $rg = "rg-$NamePrefix-fabric"
    $capacities = Invoke-AzJson @('resource', 'list', '--resource-group', $rg, '--resource-type', 'Microsoft.Fabric/capacities', '-o', 'json')
    foreach ($cap in @($capacities)) {
        if (-not $cap) { continue }
        $state = Invoke-AzJson @('resource', 'show', '--ids', $cap.id, '--query', 'properties.state', '-o', 'json')
        if ($state -eq 'Paused') {
            if ($RemovePlatformCmdlet.ShouldProcess($cap.name, 'resume capacity')) {
                if ((Invoke-AzQuiet @('fabric', 'capacity', 'resume', '--resource-group', $rg, '--capacity-name', $cap.name)) -eq 0) {
                    Write-Host "    resumed $($cap.name)"
                }
                else {
                    Write-Host "    could not resume $($cap.name); workspace deletes may fail" -ForegroundColor Yellow
                }
            }
        }
        else {
            Write-Host "    $($cap.name) is $state"
        }
    }

    Write-Step "Destroying Fabric workspaces ($($Environments -join ', '))"
    # An empty capacity key drops the fabric_capacity lookup, which fails on read
    # and aborts the destroy once the capacity itself is gone.
    foreach ($environment in $Environments) {
        Write-Host "--- $environment" -ForegroundColor DarkGray
        Invoke-TerraformDestroy `
            -Directory 'infra/workspace' `
            -BackendConfig "envs/$environment.backend.hcl" `
            -StateKey "workspace-$environment.tfstate" `
            -VarFile "envs/$environment.tfvars" `
            -VarOverrides @('capacity_key=') `
            -Label "$NamePrefix-$environment" | Out-Null
    }

    Write-Step 'Destroying the platform (capacity, pipeline, connection, RBAC)'
    # The pipeline's stage workspaces were destroyed above, so leaving the
    # pipeline enabled makes its fabric_workspace lookups fail on read and
    # aborts the destroy before the capacity, connection and RBAC are removed.
    # Turning it off empties those for_each blocks; the pipeline itself is still
    # destroyed, because destroy works from state rather than configuration.
    Invoke-TerraformDestroy `
        -Directory 'infra/platform' `
        -BackendConfig 'platform.backend.hcl' `
        -StateKey 'platform.tfstate' `
        -VarOverrides @('create_deployment_pipeline=false') `
        -Label "$NamePrefix platform" | Out-Null
}

# -----------------------------------------------------------------------------
# 2. Orphan sweep
# -----------------------------------------------------------------------------
# Everything below is matched on the lane-suffixed name, which is precisely why
# the lane belongs in the name: without it there is no safe way to tell one
# lane's leftovers from the other's.
Write-Step 'Sweeping for anything still named for this lane'

function Remove-FabricItem {
    param(
        [Parameter(Mandatory)][string] $Collection,
        [Parameter(Mandatory)][string] $Kind
    )

    $list = Invoke-AzJson @('rest', '--method', 'GET', '--url', "$FabricApi/v1/$Collection", '--resource', $FabricApi, '-o', 'json')
    if (-not $list -or $list.PSObject.Properties.Name -notcontains 'value') {
        Write-Host "    could not list $Kind (insufficient permission, or none exist)"
        return
    }

    # StrictMode turns a missing property into an error, and not every Fabric
    # collection returns displayName on every row.
    $targets = @($list.value | Where-Object {
            $_.PSObject.Properties.Name -contains 'displayName' -and
            $_.displayName -and
            $_.displayName.StartsWith("$NamePrefix-")
        })
    if (-not $targets) {
        Write-Host "    no orphaned $Kind"
        return
    }

    foreach ($item in $targets) {
        if (-not $RemovePlatformCmdlet.ShouldProcess($item.displayName, "delete $Kind")) { continue }
        if ((Invoke-AzQuiet @('rest', '--method', 'DELETE', '--url', "$FabricApi/v1/$Collection/$($item.id)", '--resource', $FabricApi)) -eq 0) {
            Write-Host "    deleted $Kind '$($item.displayName)'"
            Record -Kind $Kind -Name $item.displayName -Status 'deleted (orphan)'
        }
        else {
            Record-Failure -Kind $Kind -Name $item.displayName -Reason 'delete rejected; you may not be an admin of it'
        }
    }
}

Remove-FabricItem -Collection 'deploymentPipelines' -Kind 'deployment pipeline'
Remove-FabricItem -Collection 'workspaces' -Kind 'workspace'
Remove-FabricItem -Collection 'connections' -Kind 'connection'

# The resource group holds the capacity, so removing it catches a capacity that
# outlived its state file.
$rg = "rg-$NamePrefix-fabric"
if ((Invoke-AzQuiet @('group', 'show', '--name', $rg, '-o', 'none')) -eq 0) {
    if ($RemovePlatformCmdlet.ShouldProcess($rg, 'delete resource group')) {
        if ((Invoke-AzQuiet @('group', 'delete', '--name', $rg, '--yes')) -eq 0) {
            Write-Host "    deleted resource group $rg"
            Record -Kind 'resource group' -Name $rg -Status 'deleted'
        }
        else {
            Record-Failure -Kind 'resource group' -Name $rg -Reason 'delete failed; check for a resource lock'
        }
    }
}
else {
    Write-Host "    resource group $rg already gone"
}

# -----------------------------------------------------------------------------
# 3. App registration
# -----------------------------------------------------------------------------
Write-Step "Removing the app registration '$AppName'"
if ($KeepServicePrincipal) {
    Write-Host '    kept (-KeepServicePrincipal)'
}
else {
    $appId = az ad app list --display-name $AppName --query '[0].appId' -o tsv 2>$null
    if (-not $appId) {
        Write-Host "    '$AppName' not found"
    }
    elseif ($RemovePlatformCmdlet.ShouldProcess($AppName, 'delete app registration')) {
        # Deleting the app removes its federated credentials and service
        # principal with it; the role assignments become orphaned GUIDs that
        # Azure cleans up on its own.
        if ((Invoke-AzQuiet @('ad', 'app', 'delete', '--id', $appId)) -eq 0) {
            Write-Host "    deleted '$AppName' ($appId)"
            Record -Kind 'app registration' -Name $AppName -Status 'deleted'
        }
        else {
            Record-Failure -Kind 'app registration' -Name $AppName -Reason 'delete failed; you may not own it'
        }
    }
}

# -----------------------------------------------------------------------------
# 4. Items repository branches
# -----------------------------------------------------------------------------
if ($IncludeBranches) {
    Write-Step 'Deleting this lane''s branches in the items repository'

    if (-not $ItemsRepoPath) {
        $ItemsRepoPath = Join-Path (Split-Path -Parent $RepoRoot) 'fabric-workspace-items'
    }

    if (-not (Test-Path (Join-Path $ItemsRepoPath '.git'))) {
        Write-Host "    no git repository at $ItemsRepoPath; skipping" -ForegroundColor Yellow
    }
    else {
        Push-Location $ItemsRepoPath
        try {
            foreach ($environment in @('dev', 'test', 'prod')) {
                $branch = "$BranchPrefix$environment"
                if ($RemovePlatformCmdlet.ShouldProcess("$branch in $ItemsRepoPath", 'delete branch')) {
                    & git ls-remote --exit-code --heads $ItemsRemote "refs/heads/$branch" 2>&1 | Out-Null
                    $lookupExitCode = $LASTEXITCODE
                    if ($lookupExitCode -eq 2) {
                        Write-Host "    ($branch not on $ItemsRemote)"
                    }
                    elseif ($lookupExitCode -ne 0) {
                        Record-Failure -Kind 'branch' -Name $branch -Reason "could not query $ItemsRemote"
                    }
                    else {
                        & git push $ItemsRemote --delete $branch 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            Record-Failure -Kind 'branch' -Name $branch -Reason "delete from $ItemsRemote failed"
                            continue
                        }

                        Write-Host "    deleted remote branch $branch"
                        Record -Kind 'branch' -Name $branch -Status 'deleted'
                    }
                    & git branch -D $branch 2>&1 | Out-Null
                }
            }
        }
        finally {
            Pop-Location
        }
    }
}

# -----------------------------------------------------------------------------
# 5. Entra groups (shared)
# -----------------------------------------------------------------------------
if ($IncludeGroups) {
    Write-Step 'Deleting the shared Entra security groups'
    Write-Host '    these are shared with the other lane; make sure it is gone' -ForegroundColor Yellow

    foreach ($group in @($AdminGroup, $EngineerGroup, $AnalystGroup)) {
        $oid = az ad group list --display-name $group --query '[0].id' -o tsv 2>$null
        if (-not $oid) {
            Write-Host "    '$group' not found"
            continue
        }
        if ($RemovePlatformCmdlet.ShouldProcess($group, 'delete Entra group')) {
            if ((Invoke-AzQuiet @('ad', 'group', 'delete', '--group', $oid)) -eq 0) {
                Write-Host "    deleted '$group'"
                Record -Kind 'entra group' -Name $group -Status 'deleted'
            }
            else {
                Record-Failure -Kind 'entra group' -Name $group -Reason 'delete failed'
            }
        }
    }
}

# -----------------------------------------------------------------------------
# 6. Terraform state (shared, last)
# -----------------------------------------------------------------------------
Write-Step 'Terraform state'
if (-not $IncludeState) {
    Write-Host "    kept. Re-run with -IncludeState to delete $StateResourceGroup."
}
elseif ((Invoke-AzQuiet @('group', 'show', '--name', $StateResourceGroup, '-o', 'none')) -ne 0) {
    Write-Host "    $StateResourceGroup already gone"
}
elseif ($RemovePlatformCmdlet.ShouldProcess($StateResourceGroup, 'delete state resource group')) {
    # The CanNotDelete lock from bootstrap blocks the group delete, and also
    # blocks deleting perimeter rules, so it has to go first.
    if ((Invoke-AzQuiet @('lock', 'delete', '--name', $StateLockName, '--resource-group', $StateResourceGroup)) -eq 0) {
        Write-Host "    removed lock '$StateLockName'"
    }
    else {
        Write-Host '    (no lock found)'
    }

    if ((Invoke-AzQuiet @('group', 'delete', '--name', $StateResourceGroup, '--yes', '--no-wait')) -eq 0) {
        Write-Host "    deletion of $StateResourceGroup started (async)"
        Record -Kind 'resource group' -Name $StateResourceGroup -Status 'deleting'
    }
    else {
        Record-Failure -Kind 'resource group' -Name $StateResourceGroup -Reason 'delete failed; check for remaining locks'
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '=============================================================================' -ForegroundColor DarkGray

if ($WhatIfPreference) {
    Write-Host 'Dry run. Nothing was destroyed.' -ForegroundColor Green
}
elseif ($script:Removed.Count) {
    Write-Host "Removed ($Lane lane):" -ForegroundColor Green
    $script:Removed | Format-Table -AutoSize | Out-String | Write-Host
}
else {
    Write-Host 'Nothing to remove.' -ForegroundColor Green
}

if ($script:Failed.Count) {
    Write-Host 'Left behind:' -ForegroundColor Red
    $script:Failed | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host 'Re-run with -OrphansOnly once the cause is fixed.' -ForegroundColor Yellow
}

Write-Host @"
Not removed by any script:
  - Fabric tenant settings (Git integration, service principal API access)
  - GitHub Environments, repository variables and federated identity records
    already deleted with the app registration
  - The network security perimeter, if -IncludeState was not used
  - The other lane
=============================================================================
"@

# Tolerated non-zero exits (an absent branch, a resource group already gone) leave
# $LASTEXITCODE set, and CI reads that as the result unless the script is explicit.
if ($script:Failed.Count) { exit 1 }

exit 0
