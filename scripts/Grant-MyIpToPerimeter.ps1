<#
.SYNOPSIS
    Grants this machine's public IP inbound access to a network security perimeter.

.DESCRIPTION
    The Terraform state storage account sits inside a network security perimeter,
    so a changing public IP silently breaks terraform init with a 403. Running
    this with no arguments detects the current IP, grants it, removes every
    other IP-based inbound rule, and verifies access.

    Subscription-scoped and outbound rules are never touched: those are
    deliberate topology, not ad-hoc client access.

    The new rule is written before the old ones are deleted, so access is never
    dropped mid-run. The resource group's CanNotDelete lock is lifted for the
    cleanup and restored in a finally block.

    Uses az rest rather than the preview `az network perimeter` extension, so it
    works without installing anything.

.EXAMPLE
    ./scripts/Grant-MyIpToPerimeter.ps1

.EXAMPLE
    ./scripts/Grant-MyIpToPerimeter.ps1 -WhatIf

.EXAMPLE
    ./scripts/Grant-MyIpToPerimeter.ps1 -Ip 203.0.113.5 -KeepStale

.EXAMPLE
    ./scripts/Grant-MyIpToPerimeter.ps1 -List
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $PerimeterName = 'az-nw-security-perimeter',
    [string] $ResourceGroup = 'rg-terraform-state',
    [string] $ProfileName,
    [string] $SubscriptionId,

    # Defaults to this machine's detected public IP.
    [string] $Ip,

    [string] $StorageAccount = 'stcontosofabtfstate',
    [string] $Container = 'tfstate',

    [switch] $List,

    # By default every other IP-based inbound rule is removed, leaving exactly
    # one rule for the current address. Use this to keep them.
    [switch] $KeepStale,

    # The resource group carries a CanNotDelete lock, which also blocks deleting
    # perimeter rules. It is lifted for the cleanup and restored afterwards.
    # Use this to leave it in place and skip cleanup instead.
    [switch] $KeepLock,

    [switch] $SkipVerify
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

$ApiVersion = '2023-08-01-preview'

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }

. (Join-Path $PSScriptRoot 'StateAccountHelpers.ps1')

if (-not $PSBoundParameters.ContainsKey('PerimeterName')) {
    $resolved = Resolve-NetworkSecurityPerimeter -SubscriptionId $SubscriptionId `
        -ResourceGroup $ResourceGroup -PreferredName $PerimeterName -ApiVersion $ApiVersion

    if ($resolved.Adopted) {
        Write-Warning "Using perimeter '$($resolved.Name)'; '$PerimeterName' does not exist in '$ResourceGroup'."
        $PerimeterName = $resolved.Name
    }
    elseif (-not $resolved.Existing) {
        $found = if ($resolved.Candidates.Count) { $resolved.Candidates -join ', ' } else { 'none' }
        throw "No perimeter named '$PerimeterName' in '$ResourceGroup'. Found: $found. Pass -PerimeterName, or run New-StateFoundation.ps1 to create one."
    }
}

$PerimeterId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkSecurityPerimeters/$PerimeterName"
$PerimeterUrl = "https://management.azure.com$PerimeterId"

function Invoke-Arm {
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Url,
        [string] $BodyFile
    )
    $args = @('rest', '--method', $Method, '--url', $Url)
    if ($BodyFile) { $args += @('--headers', 'Content-Type=application/json', '--body', "@$BodyFile") }

    $raw = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az rest $Method failed: $raw" }
    if (-not "$raw".Trim()) { return $null }
    return "$raw" | ConvertFrom-Json
}

if (-not (Invoke-Arm -Method GET -Url "$($PerimeterUrl)?api-version=$ApiVersion")) {
    throw "Network security perimeter '$PerimeterName' not found in '$ResourceGroup'."
}

# Profile names are case sensitive in the URL, so read the real one rather than
# assuming defaultProfile.
if (-not $ProfileName) {
    $profiles = (Invoke-Arm -Method GET -Url "$PerimeterUrl/profiles?api-version=$ApiVersion").value
    if (-not $profiles) { throw "Perimeter '$PerimeterName' has no profiles." }
    $ProfileName = $profiles[0].name
    Write-Host "Using profile '$ProfileName'"
}

$rulesUrl = "$PerimeterUrl/profiles/$ProfileName/accessRules"
$existing = (Invoke-Arm -Method GET -Url "$($rulesUrl)?api-version=$ApiVersion").value

if ($List) {
    $existing | ForEach-Object {
        '{0,-32} {1,-9} ips={2} subs={3}' -f $_.name,
            $_.properties.direction,
            ($_.properties.addressPrefixes -join ','),
            (@($_.properties.subscriptions).Count)
    }
    return
}

if (-not $Ip) {
    $Ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
    Write-Host "Detected public IP $Ip"
}
$prefix = if ($Ip -match '/') { $Ip } else { "$Ip/32" }
$ruleName = 'inbound-ip-' + ($prefix -replace '[./]', '-')

# Create before deleting. Removing the rule that currently admits this machine
# first would cut access mid-run and leave the perimeter with no IP rule at all.
if ($PSCmdlet.ShouldProcess("$prefix on $PerimeterName/$ProfileName", 'Add inbound access rule')) {
    $tempFile = New-TemporaryFile
    try {
        $body = @{ properties = @{ direction = 'Inbound'; addressPrefixes = @($prefix) } }
        Set-Content -Path $tempFile -Value ($body | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
        Invoke-Arm -Method PUT -Url "$rulesUrl/$($ruleName)?api-version=$ApiVersion" -BodyFile $tempFile | Out-Null
        Write-Host "Rule '$ruleName' now allows $prefix"
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# Every other IP-based inbound rule is a standing grant to an address that may
# no longer belong to anyone here. Subscription-scoped and outbound rules are
# left alone: they are not ad-hoc client allowances.
if (-not $KeepStale) {
    $stale = $existing | Where-Object {
        $_.name -ne $ruleName -and
        $_.properties.direction -eq 'Inbound' -and
        @($_.properties.addressPrefixes).Count -gt 0
    }

    if (-not $stale) {
        Write-Host 'No stale IP rules to remove.'
    }

    # The CanNotDelete lock that protects Terraform state also blocks deleting
    # perimeter rules in the same resource group.
    $lockName = az lock list --resource-group $ResourceGroup --query "[?level=='CanNotDelete'].name | [0]" -o tsv 2>$null
    $lockLifted = $false

    if ($stale -and $lockName -and (-not $KeepLock)) {
        if ($PSCmdlet.ShouldProcess("$lockName on $ResourceGroup", 'Temporarily remove resource lock')) {
            & az lock delete --name $lockName --resource-group $ResourceGroup -o none 2>&1 | Out-Null
            $lockLifted = $true
            Write-Host "Temporarily removed lock '$lockName'"
        }
    }

    try {
        foreach ($rule in $stale) {
            $ips = $rule.properties.addressPrefixes -join ','
            if (-not $PSCmdlet.ShouldProcess("$($rule.name) ($ips)", 'Delete stale inbound IP rule')) { continue }

            $out = & az rest --method DELETE --url "$rulesUrl/$($rule.name)?api-version=$ApiVersion" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Removed '$($rule.name)' ($ips)"
            }
            elseif ("$out" -match 'ScopeLocked') {
                Write-Warning "Cannot delete '$($rule.name)': resource group '$ResourceGroup' has a CanNotDelete lock. Drop -KeepLock so the lock can be lifted for the cleanup."
                break
            }
            else {
                Write-Warning "Failed to delete '$($rule.name)': $out"
            }
        }
    }
    finally {
        if ($lockLifted) {
            & az lock create --name $lockName --lock-type CanNotDelete --resource-group $ResourceGroup `
                --notes 'Terraform state. Remove only during a deliberate teardown.' -o none 2>&1 | Out-Null
            Write-Host "Restored lock '$lockName'"
        }
    }
}

if ($SkipVerify) { return }

# Perimeter rules are eventually consistent and regularly take several minutes.
Write-Host 'Waiting for the rule to take effect...'
$maxAttempts = 60
$consecutiveSuccesses = 0
foreach ($attempt in 1..$maxAttempts) {
    & az storage blob list --container-name $Container --account-name $StorageAccount --auth-mode login -o none *>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $consecutiveSuccesses++
        Write-Host "Data plane probe $consecutiveSuccesses/3 succeeded."
        if ($consecutiveSuccesses -eq 3) {
            Write-Host "Data plane stable after $attempt attempt(s). Terraform can start."
            return
        }
    }
    else {
        $consecutiveSuccesses = 0
    }
    Start-Sleep -Seconds 15
}

throw @"
Still blocked after 15 minutes.

Confirm $prefix is genuinely your egress address (a VPN or proxy can change it
mid-session), and that the association access mode is Enforced rather than
pointing at a different perimeter.
"@
