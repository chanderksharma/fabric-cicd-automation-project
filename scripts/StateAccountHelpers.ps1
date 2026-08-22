<#
.SYNOPSIS
    Shared helpers for locating the Terraform state storage account.

.DESCRIPTION
    Dot-sourced by bootstrap.ps1 and New-StateFoundation.ps1 so both agree on
    where the account name comes from and what "already exists" means.

        . (Join-Path $PSScriptRoot 'StateAccountHelpers.ps1')

    Not intended to be run directly.
#>

function Get-BackendStorageAccount {
    <#
        Reads storage_account_name out of the committed backend config, which is
        the file terraform init will actually use. Learning the name from there
        rather than a hardcoded default keeps the scripts and Terraform pointed
        at the same account.
    #>
    param([Parameter(Mandatory)][string] $RepoRoot)

    $backend = Join-Path $RepoRoot 'infra/platform/platform.backend.hcl'
    if (-not (Test-Path $backend)) { return $null }

    $match = [regex]::Match((Get-Content $backend -Raw), '(?m)^\s*storage_account_name\s*=\s*"([^"]+)"')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Resolve-StateStorageAccount {
    <#
        Returns a validated account name, prompting only when one was not
        supplied and cannot be inferred.
    #>
    param(
        [string] $Name,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    if (-not $Name) {
        $suggested = Get-BackendStorageAccount -RepoRoot $RepoRoot

        # A prompt in CI would hang the job until it timed out.
        if ($env:CI -or $env:TF_IN_AUTOMATION) {
            if (-not $suggested) { throw 'No storage account name supplied and none found in infra/platform/platform.backend.hcl. Pass -StateStorageAccount.' }
            $Name = $suggested
        }
        else {
            $prompt = if ($suggested) { "Terraform state storage account [$suggested]" } else { 'Terraform state storage account name' }
            $answer = Read-Host $prompt
            $Name = if ($answer) { $answer.Trim() } else { $suggested }
        }
    }

    if (-not $Name) { throw 'A storage account name is required.' }

    # Azure rejects anything else, and the failure message is unhelpful.
    if ($Name -notmatch '^[a-z0-9]{3,24}$') {
        throw "Storage account name '$Name' is invalid. Use 3-24 lowercase letters and digits only."
    }

    return $Name
}

function Get-StateStorageAccountStatus {
    <#
        Distinguishes the three cases that matter: it is ours, it is someone
        else's, or the name is free. Creating blind conflates the first two into
        one confusing error.
    #>
    param([Parameter(Mandatory)][string] $Name)

    $existing = & az storage account show --name $Name -o json 2>$null | ConvertFrom-Json
    if ($existing) {
        return [pscustomobject]@{
            Exists        = $true
            Available     = $false
            Id            = $existing.id
            ResourceGroup = $existing.resourceGroup
            Location      = $existing.location
            Reason        = 'InSubscription'
        }
    }

    # Storage account names are globally unique, so "not in my subscription"
    # does not mean "free".
    $check = & az storage account check-name --name $Name -o json 2>$null | ConvertFrom-Json
    $available = [bool]($check -and $check.nameAvailable)

    return [pscustomobject]@{
        Exists        = $false
        Available     = $available
        Id            = $null
        ResourceGroup = $null
        Location      = $null
        Reason        = if ($available) { 'Available' } else { 'TakenByAnotherTenant' }
    }
}

function Test-StateContainer {
    param(
        [Parameter(Mandatory)][string] $AccountName,
        [Parameter(Mandatory)][string] $ContainerName
    )

    $result = & az storage container exists --name $ContainerName --account-name $AccountName --auth-mode login --query exists -o tsv 2>$null
    # A network or RBAC failure is not the same as "absent", but both mean the
    # foundation script needs to run, so they are treated alike here.
    return ($LASTEXITCODE -eq 0 -and $result -eq 'true')
}

function Resolve-NetworkSecurityPerimeter {
    <#
        Returns the perimeter this resource group actually holds.

        A perimeter cannot be renamed in place, so an estate built before the
        default name changed still carries the old one. Creating the configured
        name instead would leave the storage account associated with the first
        perimeter and the access rules being written to the second, which reads
        as a permissions problem and is not one.

        Adoption only happens when the group holds exactly one perimeter, so
        this can never silently pick between two estates.
    #>
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $PreferredName,
        [string] $ApiVersion = '2023-08-01-preview'
    )

    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkSecurityPerimeters?api-version=$ApiVersion"
    $raw = & az rest --method GET --url $url 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Name = $PreferredName; Existing = $false; Adopted = $false; Candidates = @() }
    }

    $names = @(("$raw" | ConvertFrom-Json).value | ForEach-Object { $_.name })

    if ($names -contains $PreferredName) {
        return [pscustomobject]@{ Name = $PreferredName; Existing = $true; Adopted = $false; Candidates = $names }
    }
    if ($names.Count -eq 1) {
        return [pscustomobject]@{ Name = $names[0]; Existing = $true; Adopted = $true; Candidates = $names }
    }
    return [pscustomobject]@{ Name = $PreferredName; Existing = $false; Adopted = $false; Candidates = $names }
}
