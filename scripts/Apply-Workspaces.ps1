<#
.SYNOPSIS
    Applies the workspace Terraform root across dev, test and prod.

.DESCRIPTION
    Each environment has its own state file, selected by the backend config.
    Running `terraform apply -var environment=prod` without re-initialising the
    backend does NOT create a second workspace - it renames the one already in
    whichever state file happens to be active. This script always pairs
    `init -reconfigure` with the matching `-var-file` so that cannot happen.

    Order is dev, test, prod so a failure stops before it reaches production.

.EXAMPLE
    . ./scripts/Load-Env.ps1
    ./scripts/Apply-Workspaces.ps1

.EXAMPLE
    ./scripts/Apply-Workspaces.ps1 -Environments dev -PlanOnly
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'test', 'prod')]
    [string[]] $Environments = @('dev', 'test', 'prod'),

    # Defaults to TF_VAR_lane if Load-Env.ps1 has run, otherwise ml.
    [ValidateSet('gh', 'ml')]
    [string] $Lane,

    # Names the workspaces and branches, replacing the derived <prefix>-<lane>.
    # Defaults to TF_VAR_workspace_prefix so .env can carry it.
    [ValidatePattern('^$|^[a-z][a-z0-9-]{2,30}$', Options = 'None')]
    [string] $WorkspacePrefix,

    [string] $ContainerPrefix = 'tfstate',

    [switch] $PlanOnly,
    [switch] $AutoApprove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Lane) {
    $Lane = if ($env:TF_VAR_lane) { $env:TF_VAR_lane } else { 'ml' }
}
$env:TF_VAR_lane = $Lane

if (-not $PSBoundParameters.ContainsKey('WorkspacePrefix')) {
    $WorkspacePrefix = $env:TF_VAR_workspace_prefix
}
$env:TF_VAR_workspace_prefix = $WorkspacePrefix

$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'infra/workspace'

if (-not $env:ARM_TENANT_ID -and -not $env:TF_VAR_tenant_id) {
    Write-Warning 'Neither TF_VAR_tenant_id nor ARM_TENANT_ID is set. Terraform will fall back to the current az session.'
}

Write-Host "Lane: $Lane" -ForegroundColor Yellow
Write-Host "Workspace prefix: $(if ($WorkspacePrefix) { $WorkspacePrefix } else { "(derived from prefix and lane)" })" -ForegroundColor Yellow

$results = @()

# Push-Location rather than terraform -chdir: PowerShell passes "-chdir=$root"
# to native commands without expanding the variable.
Push-Location $root
try {
    foreach ($environment in $Environments) {
        Write-Host ""
        Write-Host "=== $environment ($Lane) ===" -ForegroundColor Cyan

        # The lane-specific container overrides the one in the backend file; a
        # later -backend-config wins. Without it both lanes would share one
        # state file and the second apply would rename the first lane's
        # workspace.
        & terraform init -reconfigure -no-color `
            -backend-config="envs/$environment.backend.hcl" `
            -backend-config="container_name=$ContainerPrefix-$Lane"
        if ($LASTEXITCODE -ne 0) { throw "terraform init failed for $environment" }

        if ($PlanOnly) {
            & terraform plan -no-color -var-file="envs/$environment.tfvars"
            if ($LASTEXITCODE -ne 0) { throw "terraform plan failed for $environment" }
            continue
        }

        if ($AutoApprove) {
            & terraform apply -no-color -auto-approve -var-file="envs/$environment.tfvars"
        }
        else {
            & terraform apply -no-color -var-file="envs/$environment.tfvars"
        }
        if ($LASTEXITCODE -ne 0) { throw "terraform apply failed for $environment" }

        $results += [pscustomobject]@{
            Lane        = $Lane
            Environment = $environment
            Workspace   = (& terraform output -raw workspace_name)
            WorkspaceId = (& terraform output -raw workspace_id)
            Git         = (& terraform output -raw git_integration_enabled)
        }
    }
}
finally {
    Pop-Location
}

if ($results) {
    Write-Host ""
    Write-Host "Workspaces:" -ForegroundColor Green
    $results | Format-Table -AutoSize
    Write-Host "Item content arrives through Git integration; commit to the branch each workspace syncs with."
}
