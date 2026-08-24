#Requires -Version 7.0

<#
.SYNOPSIS
    Grants or revokes the deployment identity's Azure roles around a single run.

.DESCRIPTION
    The deployment principal needs Contributor to create the capacity resource
    group and User Access Administrator to write the role assignments inside it.
    Holding either permanently is what a subscription-scope standing grant means,
    so this script hands them over for the length of a workflow run and takes them
    back afterwards.

    Run it as an identity that can write role assignments; the deployment
    principal cannot elevate itself. Storage Blob Data Contributor on the state
    account is deliberately out of scope: it is narrow, and Terraform cannot read
    state without it.

    Grant is idempotent, and Revoke removes only an exact match on principal,
    role and scope, so an assignment made for another reason survives.

.EXAMPLE
    ./scripts/Set-DeploymentRbac.ps1 -Action Grant -PrincipalObjectId <oid> -SubscriptionId <sub>

.EXAMPLE
    ./scripts/Set-DeploymentRbac.ps1 -Action Revoke -PrincipalObjectId <oid> -SubscriptionId <sub>
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Grant', 'Revoke')]
    [string] $Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $PrincipalObjectId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    # Contributor has to sit at subscription scope because creating a resource
    # group is a subscription-level write.
    [string] $Scope = '',

    [string[]] $Roles = @('Contributor', 'User Access Administrator')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Non-zero exits are inspected rather than thrown, so "already gone" stays benign.
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Scope) { $Scope = "/subscriptions/$SubscriptionId" }

Write-Host "Principal : $PrincipalObjectId"
Write-Host "Scope     : $Scope"
Write-Host "Action    : $Action"

function Get-Assignment {
    param([Parameter(Mandatory)][string] $Role)

    $raw = & az role assignment list `
        --assignee $PrincipalObjectId `
        --role $Role `
        --scope $Scope `
        --query "[?scope=='$Scope'].id" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
    $global:LASTEXITCODE = 0

    return (@($raw) | Where-Object { $_ } | Select-Object -First 1)
}

$failed = 0

foreach ($role in $Roles) {
    $existing = Get-Assignment -Role $role

    if ($Action -eq 'Grant') {
        if ($existing) {
            Write-Host "  '$role' already assigned"
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$role at $Scope", 'grant')) { continue }

        # The object ID is used directly so no Microsoft Graph read is needed.
        & az role assignment create `
            --assignee-object-id $PrincipalObjectId `
            --assignee-principal-type ServicePrincipal `
            --role $role `
            --scope $Scope -o none 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $global:LASTEXITCODE = 0
            Write-Host "  FAILED to grant '$role'" -ForegroundColor Red
            $failed++
            continue
        }
        Write-Host "  granted '$role'"
    }
    else {
        if (-not $existing) {
            Write-Host "  '$role' already absent"
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$role at $Scope", 'revoke')) { continue }

        & az role assignment delete --ids $existing -o none 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $global:LASTEXITCODE = 0
            Write-Host "  FAILED to revoke '$role'; it is still standing" -ForegroundColor Red
            $failed++
            continue
        }
        Write-Host "  revoked '$role'"
    }
}

if ($failed -gt 0) { exit 1 }
exit 0
