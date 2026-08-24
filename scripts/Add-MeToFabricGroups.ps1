#Requires -Version 7.0

<#
.SYNOPSIS
    Adds the signed-in user to the Fabric security groups.

.DESCRIPTION
    Terraform grants workspace roles to groups and never to individuals, so a
    person gains access by joining one. Nobody sees a workspace until then,
    including whoever built the platform: bootstrap adds the identity it ran as,
    which in CI is a service principal rather than your account.

    Membership is checked before it is written, so re-running changes nothing.

    Fabric stores the group's object ID rather than its name. A group that was
    deleted and recreated is a new object, so this has to be repeated after a
    teardown and rebuild even though the names look unchanged.

.EXAMPLE
    # The common case: gain administrator access to the workspaces.
    ./scripts/Add-MeToFabricGroups.ps1

.EXAMPLE
    # Join all three, for a sandbox where one person plays every role.
    ./scripts/Add-MeToFabricGroups.ps1 -All

.EXAMPLE
    ./scripts/Add-MeToFabricGroups.ps1 -All -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Defaults match the names bootstrap creates.
    [string] $AdminGroup = 'sg-fabric-platform-admins',
    [string] $EngineerGroup = 'sg-fabric-data-engineers',
    [string] $AnalystGroup = 'sg-fabric-analysts',

    # Join the engineer and analyst groups as well. Admin alone is enough to
    # administer every workspace; the others only widen what dev and test show.
    [switch] $All
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script reads $LASTEXITCODE to tell "absent" from "failed", so a non-zero
# native exit must not terminate on its own.
$PSNativeCommandUseErrorActionPreference = $false

$memberId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $memberId) {
    throw 'Could not resolve the signed-in user. Run `az login` first. A service principal session cannot use this script, because /me needs a delegated token.'
}
$upn = az ad signed-in-user show --query userPrincipalName -o tsv 2>$null
Write-Host "Signed in as $upn ($memberId)"

# The @() is load-bearing: an if expression returning one item hands back a
# string, and .Count on a string throws under Set-StrictMode.
[string[]] $targets = @(if ($All) { $AdminGroup; $EngineerGroup; $AnalystGroup } else { $AdminGroup })

$missing = 0
foreach ($name in $targets) {
    $groupId = az ad group list --display-name $name --query "[0].id" -o tsv 2>$null
    if (-not $groupId) {
        Write-Warning "Group '$name' does not exist. Create it with scripts/bootstrap.ps1 -CreateGroups."
        $missing++
        continue
    }

    if ((az ad group member check --group $groupId --member-id $memberId --query value -o tsv 2>$null) -eq 'true') {
        Write-Host ("  {0,-28} {1}  already a member" -f $name, $groupId)
        continue
    }

    if (-not $PSCmdlet.ShouldProcess("$name ($groupId)", 'add signed-in user')) { continue }

    $output = az ad group member add --group $groupId --member-id $memberId 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to add you to '$name': $output"
    }
    Write-Host ("  {0,-28} {1}  added" -f $name, $groupId)
}

if ($missing -eq $targets.Count) {
    throw 'None of the groups exist. Run scripts/bootstrap.ps1 -CreateGroups.'
}

Write-Host ''
Write-Host 'Fabric caches group membership, so allow a few minutes before the workspaces appear.'
