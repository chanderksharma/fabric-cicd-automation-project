<#
.SYNOPSIS
    Loads .env into the current session as TF_VAR_* and ARM_* variables.

.DESCRIPTION
    Gives a local shell the same inputs the GitHub workflows receive from
    Environment variables, so Terraform behaves identically in both places.

    Every value is optional. Anything absent from .env is resolved from the
    current Azure CLI session, so `az login` alone is enough to work in the ml
    lane. .env exists to pin values, not to supply them.

    Dot-source it so the variables persist in your session:

        . ./scripts/Load-Env.ps1

    Running it normally (./scripts/Load-Env.ps1) sets variables in a child
    scope that disappears on exit, which is almost never what you want.

.EXAMPLE
    . ./scripts/Load-Env.ps1 -Lane gh
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env'),

    # Which lane the session targets. Overrides FABRIC_LANE in .env.
    [ValidateSet('gh', 'ml')]
    [string] $Lane
)

$ErrorActionPreference = 'Stop'

$values = @{}
if (Test-Path $Path) {
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        $name, $value = $trimmed -split '=', 2
        if (-not $value) { continue }

        $values[$name.Trim()] = $value.Trim().Trim('"', "'")
    }
    Write-Host "Loaded $Path"
}
else {
    Write-Host "No .env at $Path; resolving everything from the current az session."
}

# Fall back to the signed-in session rather than failing. An empty .env and a
# fresh `az login` is a complete configuration for the ml lane.
$account = $null
function Get-AzAccountValue {
    param([Parameter(Mandatory)][string] $Query)
    if (-not $script:account) {
        $raw = az account show -o json 2>$null
        if (-not $raw) { return $null }
        $script:account = $raw | ConvertFrom-Json
    }
    return $script:account.$Query
}

function Resolve-Value {
    param(
        [Parameter(Mandatory)][string] $Key,
        [string] $AccountProperty
    )
    if ($values.ContainsKey($Key) -and $values[$Key]) { return $values[$Key] }
    if ($AccountProperty) { return (Get-AzAccountValue -Query $AccountProperty) }
    return $null
}

$tenantId = Resolve-Value -Key 'AZURE_TENANT_ID' -AccountProperty 'tenantId'
$subscriptionId = Resolve-Value -Key 'AZURE_SUBSCRIPTION_ID' -AccountProperty 'id'
$cicdObjectId = Resolve-Value -Key 'FABRIC_CICD_SP_OBJECT_ID'
$connectionId = Resolve-Value -Key 'FABRIC_GITHUB_CONNECTION_ID'
$workspacePrefix = Resolve-Value -Key 'FABRIC_WORKSPACE_PREFIX'

if (-not $tenantId -or -not $subscriptionId) {
    throw 'Could not determine tenant or subscription. Run `az login`, or set AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID in .env.'
}

$placeholder = @('AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'FABRIC_CICD_SP_OBJECT_ID') |
    Where-Object { $values.ContainsKey($_) -and $values[$_] -match '^0{8}-0{4}-0{4}-0{4}-0{12}$' }
if ($placeholder) {
    Write-Warning "Still set to the placeholder GUID: $($placeholder -join ', ')"
}

if (-not $Lane) {
    $Lane = if ($values.ContainsKey('FABRIC_LANE') -and $values['FABRIC_LANE']) { $values['FABRIC_LANE'] } else { 'ml' }
}
if ($Lane -notin @('gh', 'ml')) { throw "FABRIC_LANE must be gh or ml, got '$Lane'." }

if ($workspacePrefix -and $workspacePrefix -cnotmatch '^[a-z][a-z0-9-]{2,30}$') {
    throw "FABRIC_WORKSPACE_PREFIX must be 3-31 lowercase characters starting with a letter, got '$workspacePrefix'."
}

# Terraform input variables. Same names the workflows pass.
$env:TF_VAR_lane = $Lane
$env:TF_VAR_tenant_id = $tenantId
$env:TF_VAR_subscription_id = $subscriptionId

# Absent means "the caller is the administrator", which is how the ml lane runs.
if ($cicdObjectId) {
    $env:TF_VAR_cicd_service_principal_object_id = $cicdObjectId
}
else {
    Remove-Item env:TF_VAR_cicd_service_principal_object_id -ErrorAction SilentlyContinue
}

# Optional: only needed once the Fabric GitHub connection exists.
if ($connectionId) {
    $env:TF_VAR_github_connection_id = $connectionId
}
else {
    Remove-Item env:TF_VAR_github_connection_id -ErrorAction SilentlyContinue
}

# Absent means names derive from prefix and lane. Removed rather than left empty,
# so a stale value from an earlier shell cannot rename the estate.
if ($workspacePrefix) {
    $env:TF_VAR_workspace_prefix = $workspacePrefix
}
else {
    Remove-Item env:TF_VAR_workspace_prefix -ErrorAction SilentlyContinue
}

# Provider configuration. ARM_USE_OIDC is deliberately NOT set: locally the
# providers authenticate with the Azure CLI session, and setting it would make
# Terraform look for a GitHub token that does not exist.
$env:ARM_TENANT_ID = $tenantId
$env:ARM_SUBSCRIPTION_ID = $subscriptionId

Write-Host "  TF_VAR_lane                             = $($env:TF_VAR_lane)"
if ($env:TF_VAR_workspace_prefix) {
    Write-Host "  TF_VAR_workspace_prefix                 = $($env:TF_VAR_workspace_prefix)"
}
else {
    Write-Host '  TF_VAR_workspace_prefix                 = (unset; names derive from prefix and lane)'
}
Write-Host "  TF_VAR_tenant_id                        = $($env:TF_VAR_tenant_id)"
Write-Host "  TF_VAR_subscription_id                  = $($env:TF_VAR_subscription_id)"
if ($env:TF_VAR_cicd_service_principal_object_id) {
    Write-Host "  TF_VAR_cicd_service_principal_object_id = $($env:TF_VAR_cicd_service_principal_object_id)"
}
else {
    Write-Host '  TF_VAR_cicd_service_principal_object_id = (unset; you are the administrator)'
}
if ($env:TF_VAR_github_connection_id) {
    Write-Host "  TF_VAR_github_connection_id             = $($env:TF_VAR_github_connection_id)"
}
else {
    Write-Host '  TF_VAR_github_connection_id             = (unset; Git integration will be skipped)'
}
