<#
.SYNOPSIS
    Enables the Fabric tenant settings required for GitHub Git integration.

.DESCRIPTION
    Run with no arguments. It handles everything internally:

      1. Acquires a token for the Fabric admin API. A service principal is
         authorised by the admin-API tenant settings rather than by a delegated
         scope, so CI can use the identity it already signed in with. A user
         needs Tenant.ReadWrite.All, and the Azure CLI's own app only requests
         user_impersonation, so that path signs in with a device code through an
         app registration this script creates and consents.
      2. Finds the Git integration settings by inspecting the live list rather
         than assuming an API name.
      3. Enables them, scoped to a security group.

    The caller must be Fabric Administrator, Power BI Administrator or Global
    Administrator, or a service principal already allowed to call the admin
    APIs. These settings are tenant-wide, so they are scoped to a group by
    default rather than the whole organisation.

    The first run in a tenant has to be interactive. A service principal reaches
    the admin API only after an administrator enables the two admin API service
    principal settings in the admin portal, which this script does not manage:
    they grant tenant-wide metadata access and are a deliberate decision.

.EXAMPLE
    ./scripts/Enable-FabricGitIntegration.ps1

.EXAMPLE
    ./scripts/Enable-FabricGitIntegration.ps1 -List

.EXAMPLE
    ./scripts/Enable-FabricGitIntegration.ps1 -IncludeServicePrincipal -WhatIf

.EXAMPLE
    # Grant CI unattended access. Run once, interactively, as a Fabric admin.
    ./scripts/Enable-FabricGitIntegration.ps1 `
        -IncludeServicePrincipal `
        -IncludeAdminApiAccess `
        -PrincipalObjectId <deployment-sp-object-id>, <bootstrap-sp-object-id>

.EXAMPLE
    # Unattended, once a service principal is allowed to call the admin API.
    ./scripts/Enable-FabricGitIntegration.ps1 -Auth ServicePrincipal -IncludeServicePrincipal
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SecurityGroup = 'sg-fabric-platform-admins',

    # Optional principals whose membership in SecurityGroup must be verified.
    # Bootstrap passes the permanent deployment service principal here; add the
    # bootstrap principal too when granting admin API access.
    [string[]] $PrincipalObjectId = @(),

    # Also enable the settings that let a service principal call Fabric APIs,
    # which CI needs.
    [switch] $IncludeServicePrincipal,

    # Also enable the two admin API switches, without which a service principal
    # cannot run this script unattended. They grant the allowed group tenant-wide
    # metadata access, so opt in deliberately.
    [switch] $IncludeAdminApiAccess,

    # Show the matching settings and their state, change nothing.
    [switch] $List,

    # Apply tenant-wide instead of scoping to a security group.
    [switch] $WholeTenant,

    # How the admin API is reached. Auto tries the signed-in identity first,
    # which is what lets CI run unattended, then falls back to a device code.
    [ValidateSet('Auto', 'ServicePrincipal', 'DeviceCode')]
    [string] $Auth = 'Auto',

    [string] $AppName = 'fabric-admin-cli',
    [string] $TenantId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

$FabricResource = 'https://api.fabric.microsoft.com'
$AdminRoot = "$FabricResource/v1/admin/tenantsettings"
$PowerBiAppId = '00000009-0000-0000-c000-000000000000'
$TenantReadWriteScopeId = 'd594897b-76e7-4b2b-984b-b4adff35e109'
$Scope = 'https://analysis.windows.net/powerbi/api/Tenant.ReadWrite.All offline_access'

if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }

# --------------------------------------------------------------------------
# 1. A token for the admin API
# --------------------------------------------------------------------------
function Test-AdminApiReachable {
    param([Parameter(Mandatory)][string] $Token)

    try {
        Invoke-RestMethod -Method Get -Uri $AdminRoot -Headers @{ Authorization = "Bearer $Token" } | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

$accessToken = $null

if ($Auth -ne 'DeviceCode') {
    # An app-only token carries no delegated scope; Fabric authorises it through
    # the service principal admin-API tenant settings instead.
    $sessionToken = az account get-access-token --resource $FabricResource --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; $sessionToken = $null }

    if ($sessionToken -and (Test-AdminApiReachable -Token $sessionToken)) {
        $accessToken = $sessionToken
        Write-Host 'Using the signed-in identity; the admin API accepted its token.'
    }
    elseif ($Auth -eq 'ServicePrincipal') {
        throw "The signed-in identity cannot reach $AdminRoot. A Fabric administrator has to enable 'Service principals can access read-only admin APIs' and 'Service principals can access admin APIs used for updates' for a security group this identity belongs to. Those switches are not among the settings this script manages."
    }
    else {
        Write-Host 'The signed-in identity cannot reach the admin API; falling back to device code.'
    }
}

if (-not $accessToken) {
    # Device code needs a human; CI would otherwise wait here until it expired.
    if ($env:CI -or $env:TF_IN_AUTOMATION) {
        throw 'Device code sign-in cannot run unattended. Run this script from a workstation as a Fabric administrator, or re-run the workflow with configure_tenant_settings disabled. Unattended runs additionally need a Fabric administrator to enable the two admin API service principal settings in the admin portal; this script does not manage those.'
    }

    # ----------------------------------------------------------------------
    # App registration with the admin scope
    # ----------------------------------------------------------------------
    $clientId = az ad app list --display-name $AppName --query '[0].appId' -o tsv
    if (-not $clientId) {
        Write-Host "Creating app registration '$AppName'"
        # Public client: device code flow, so there is no secret to store or rotate.
        $clientId = az ad app create `
            --display-name $AppName `
            --sign-in-audience AzureADMyOrg `
            --is-fallback-public-client true `
            --public-client-redirect-uris "http://localhost" `
            --query appId -o tsv

        az ad sp create --id $clientId -o none 2>&1 | Out-Null
        az ad app permission add --id $clientId --api $PowerBiAppId --api-permissions "$TenantReadWriteScopeId=Scope" -o none 2>&1 | Out-Null

        foreach ($attempt in 1..3) {
            & az ad app permission admin-consent --id $clientId 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            if ($attempt -eq 3) {
                throw "Admin consent failed for $clientId. Grant Tenant.ReadWrite.All in Entra ID > App registrations > API permissions, then re-run."
            }
            Start-Sleep -Seconds 10
        }
        Write-Host "  created and consented ($clientId)"
    }
    else {
        Write-Host "Using app registration '$AppName' ($clientId)"
    }

    # ----------------------------------------------------------------------
    # Device code sign-in
    # ----------------------------------------------------------------------
    $deviceCode = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $clientId; scope = $Scope }

    Write-Host ''
    Write-Host $deviceCode.message -ForegroundColor Cyan
    Write-Host ''

    $deadline = (Get-Date).AddSeconds($deviceCode.expires_in)
    while (-not $accessToken -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $deviceCode.interval
        try {
            $accessToken = (Invoke-RestMethod -Method Post `
                    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                    -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $clientId
                    device_code = $deviceCode.device_code
                }).access_token
        }
        catch {
            if ($_.ErrorDetails.Message -notmatch 'authorization_pending') {
                throw "Device code sign-in failed: $($_.ErrorDetails.Message)"
            }
        }
    }
    if (-not $accessToken) { throw 'Device code expired before sign-in completed.' }
}

$headers = @{
    Authorization       = "Bearer $accessToken"
    'Content-Type'      = 'application/json'
    'x-ms-fabric-skill' = 'git-integration-operations-cli'
}

function Get-Settings {
    (Invoke-RestMethod -Method Get -Uri $AdminRoot -Headers $headers).tenantSettings
}

function Get-RestErrorMessage {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord)

    # ErrorDetails is absent for transport-level failures, and StrictMode makes
    # reading through it fatal.
    $details = $ErrorRecord.ErrorDetails
    if ($details -and -not [string]::IsNullOrWhiteSpace($details.Message)) {
        return $details.Message
    }
    return $ErrorRecord.Exception.Message
}

function Get-SettingGroups {
    param(
        [Parameter(Mandatory)] $Setting,
        [Parameter(Mandatory)][string] $PropertyName
    )

    $property = $Setting.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

# A destroyed and rebuilt security group keeps its name but not its id, and Fabric
# holds the old one until something rewrites the setting. Re-sending a dead id
# fails the whole update with a bare BadRequest.
$script:GroupExists = @{}
function Test-GroupExists {
    param([Parameter(Mandatory)][string] $GraphId)

    if (-not $script:GroupExists.ContainsKey($GraphId)) {
        & az ad group show --group $GraphId --query id -o tsv *>&1 | Out-Null
        $script:GroupExists[$GraphId] = $LASTEXITCODE -eq 0
        $global:LASTEXITCODE = 0
    }
    return $script:GroupExists[$GraphId]
}

function Select-LiveGroups {
    param(
        [Parameter(Mandatory)] $Setting,
        [Parameter(Mandatory)][string] $PropertyName
    )

    $kept = @()
    foreach ($group in Get-SettingGroups -Setting $Setting -PropertyName $PropertyName) {
        if (Test-GroupExists -GraphId $group.graphId) {
            $kept += $group
            continue
        }
        Write-Host "    dropping '$($group.name)' ($($group.graphId)) from $($Setting.settingName): that group no longer exists" -ForegroundColor Yellow
    }
    return @($kept)
}

function Test-SettingConfigured {
    param(
        [Parameter(Mandatory)] $Setting,
        [string] $ExpectedGroupId,
        [switch] $ExpectWholeTenant
    )

    if (-not $Setting.enabled) { return $false }

    $enabledGroups = @(Get-SettingGroups -Setting $Setting -PropertyName 'enabledSecurityGroups')
    $excludedGroups = @(Get-SettingGroups -Setting $Setting -PropertyName 'excludedSecurityGroups')

    if ($ExpectWholeTenant -or -not $Setting.canSpecifySecurityGroups) {
        return $enabledGroups.Count -eq 0 -and $excludedGroups.Count -eq 0
    }

    $isEnabled = @($enabledGroups | Where-Object { $_.graphId -eq $ExpectedGroupId }).Count -gt 0
    $isExcluded = @($excludedGroups | Where-Object { $_.graphId -eq $ExpectedGroupId }).Count -gt 0
    return $isEnabled -and -not $isExcluded
}

# --------------------------------------------------------------------------
# 2. Find the relevant settings from the live list
# --------------------------------------------------------------------------
$all = Get-Settings

$requiredSettingNames = @(
    'GitIntegrationTenantSwitch'
    'GitHubTenantSettings'
)
if ($IncludeServicePrincipal) {
    $requiredSettingNames += @(
        'ServicePrincipalAccessGlobalAPIs'
        'ServicePrincipalAccessPermissionAPIs'
    )
}

# These two are matched on title: their API names are not documented, and
# guessing one would silently enable the wrong tenant-wide switch.
if ($IncludeAdminApiAccess) {
    foreach ($title in @(
            'Service principals can access read-only admin APIs'
            'Service principals can access admin APIs used for updates'
        )) {
        $matched = @($all | Where-Object {
                $_.PSObject.Properties.Name -contains 'title' -and $_.title -eq $title
            })
        if ($matched.Count -ne 1) {
            throw "Expected exactly one tenant setting titled '$title', found $($matched.Count). Enable it in the Fabric admin portal instead."
        }
        $requiredSettingNames += $matched[0].settingName
    }
}

$settingsByName = @{}
foreach ($setting in $all) {
    $settingsByName[$setting.settingName] = $setting
}

$missingSettings = @($requiredSettingNames | Where-Object { -not $settingsByName.ContainsKey($_) })
if ($missingSettings.Count -gt 0) {
    throw "Required Fabric tenant settings were not returned: $($missingSettings -join ', '). The account may lack Fabric admin rights."
}

$targets = @($requiredSettingNames | ForEach-Object { $settingsByName[$_] })

Write-Host 'Required tenant settings:'
# A CI console is narrow, and the default width drops the columns that explain a
# rejected update.
$targets | Select-Object settingName, enabled, canSpecifySecurityGroups, `
@{ Name = 'EnabledGroups'; Expression = { @(Get-SettingGroups -Setting $_ -PropertyName 'enabledSecurityGroups').Count } }, `
@{ Name = 'ExcludedGroups'; Expression = { @(Get-SettingGroups -Setting $_ -PropertyName 'excludedSecurityGroups').Count } } | `
    Format-Table -AutoSize | Out-String -Width 500 | Write-Host

if ($List) { return }

# --------------------------------------------------------------------------
# 3. Enable whatever is still off
# --------------------------------------------------------------------------
$groupId = $null
if (-not $WholeTenant) {
    $groupId = az ad group list --display-name $SecurityGroup --query '[0].id' -o tsv
    if (-not $groupId) { throw "Security group '$SecurityGroup' not found. Pass -WholeTenant to apply tenant-wide instead." }

    foreach ($principal in $PrincipalObjectId) {
        $isMember = az ad group member check --group $groupId --member-id $principal --query value -o tsv
        if ($LASTEXITCODE -ne 0 -or $isMember -ne 'true') {
            throw "Principal '$principal' is not a direct member of '$SecurityGroup'; scoped Fabric settings would not apply to it."
        }
    }
}

$changed = 0
foreach ($setting in $targets) {
    if (Test-SettingConfigured -Setting $setting -ExpectedGroupId $groupId -ExpectWholeTenant:$WholeTenant) {
        continue
    }

    if (-not $PSCmdlet.ShouldProcess("$($setting.settingName) ($($setting.title))", 'Enable tenant setting')) { continue }

    $body = @{ enabled = $true }
    # Not every setting supports group scoping; sending groups to one that does
    # not is rejected.
    if ($groupId -and $setting.canSpecifySecurityGroups) {
        $enabledGroups = @(Select-LiveGroups -Setting $setting -PropertyName 'enabledSecurityGroups')
        if (-not ($enabledGroups | Where-Object { $_.graphId -eq $groupId })) {
            $enabledGroups += [pscustomobject]@{ graphId = $groupId; name = $SecurityGroup }
        }

        $body.enabledSecurityGroups = @($enabledGroups | ForEach-Object {
                @{ graphId = $_.graphId; name = $_.name }
            })
        $excludedGroups = @(Select-LiveGroups -Setting $setting -PropertyName 'excludedSecurityGroups' | `
                Where-Object { $_.graphId -ne $groupId } | ForEach-Object {
                @{ graphId = $_.graphId; name = $_.name }
            })
        if ($excludedGroups.Count -gt 0) {
            $body.excludedSecurityGroups = $excludedGroups
        }
    }

    try {
        Invoke-RestMethod -Method Post -Uri "$AdminRoot/$($setting.settingName)/update" `
            -Headers $headers -Body ($body | ConvertTo-Json -Depth 6) | Out-Null
        $scopeText = if ($body.ContainsKey('enabledSecurityGroups')) { "scoped to $SecurityGroup" } else { 'tenant-wide' }
        Write-Host "  enabled $($setting.settingName) ($scopeText)"
        $changed++
    }
    catch {
        # Reading the settings and updating them sit behind two different service
        # principal switches, so a successful list does not imply a writable one.
        # The body and the live shape are logged because Fabric answers an
        # unacceptable transition with a bare BadRequest.
        throw (@(
                "Could not configure $($setting.settingName): $(Get-RestErrorMessage -ErrorRecord $_)"
                "Request body: $($body | ConvertTo-Json -Depth 6 -Compress)"
                "Live setting: $($setting | ConvertTo-Json -Depth 4 -Compress)"
            ) -join [Environment]::NewLine)
    }
}

if (-not $WhatIfPreference) {
    $verifiedSettings = Get-Settings
    $verificationFailures = foreach ($settingName in $requiredSettingNames) {
        $setting = $verifiedSettings | Where-Object { $_.settingName -eq $settingName } | Select-Object -First 1
        if (-not $setting -or -not (Test-SettingConfigured -Setting $setting -ExpectedGroupId $groupId -ExpectWholeTenant:$WholeTenant)) {
            $settingName
        }
    }
    if ($verificationFailures) {
        throw "Fabric did not report the required tenant-setting state after update: $($verificationFailures -join ', ')."
    }
}

# Lets the caller skip a propagation wait that has nothing to wait for.
if ($env:GITHUB_OUTPUT) {
    "changed=$changed" | Add-Content -Path $env:GITHUB_OUTPUT -Encoding utf8
}

if ($WhatIfPreference) {
    Write-Host 'Dry run. Nothing was changed.'
}
elseif ($changed -eq 0) {
    Write-Host 'Nothing to change; all required settings already have the requested scope.'
}else {
    Write-Host ''
    Write-Host "Changed $changed setting(s). Allow up to 15 minutes for propagation, then:"
    Write-Host '  ./scripts/Apply-Workspaces.ps1'
}
