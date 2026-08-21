<#
.SYNOPSIS
    Enables the Fabric tenant settings required for GitHub Git integration.

.DESCRIPTION
    Run with no arguments. It handles everything internally:

      1. Ensures an app registration exists with the delegated Power BI Service
         scope Tenant.ReadWrite.All, and grants admin consent. The Azure CLI's
         own app only requests user_impersonation, so `az rest` cannot reach
         /v1/admin/* no matter which directory roles the caller holds.
      2. Signs in with a device code through that app.
      3. Finds the Git integration settings by inspecting the live list rather
         than assuming an API name.
      4. Enables them, scoped to a security group.

    The signed-in user must be Fabric Administrator, Power BI Administrator or
    Global Administrator. These settings are tenant-wide, so they are scoped to
    a group by default rather than the whole organisation.

.EXAMPLE
    ./scripts/Enable-FabricGitIntegration.ps1

.EXAMPLE
    ./scripts/Enable-FabricGitIntegration.ps1 -List

.EXAMPLE
    ./scripts/Enable-FabricGitIntegration.ps1 -IncludeServicePrincipal -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SecurityGroup = 'sg-fabric-platform-admins',

    # Optional principal whose membership in SecurityGroup must be verified.
    # Bootstrap passes the permanent deployment service principal here.
    [string] $PrincipalObjectId,

    # Also enable the settings that let a service principal call Fabric APIs,
    # which CI needs.
    [switch] $IncludeServicePrincipal,

    # Show the matching settings and their state, change nothing.
    [switch] $List,

    # Apply tenant-wide instead of scoping to a security group.
    [switch] $WholeTenant,

    [string] $AppName = 'fabric-admin-cli',
    [string] $TenantId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

$AdminRoot = 'https://api.fabric.microsoft.com/v1/admin/tenantsettings'
$PowerBiAppId = '00000009-0000-0000-c000-000000000000'
$TenantReadWriteScopeId = 'd594897b-76e7-4b2b-984b-b4adff35e109'
$Scope = 'https://analysis.windows.net/powerbi/api/Tenant.ReadWrite.All offline_access'

if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }

# --------------------------------------------------------------------------
# 1. App registration with the admin scope
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# 2. Device code sign-in
# --------------------------------------------------------------------------
$deviceCode = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $clientId; scope = $Scope }

Write-Host ''
Write-Host $deviceCode.message -ForegroundColor Cyan
Write-Host ''

$accessToken = $null
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

$headers = @{
    Authorization       = "Bearer $accessToken"
    'Content-Type'      = 'application/json'
    'x-ms-fabric-skill' = 'git-integration-operations-cli'
}

function Get-Settings {
    (Invoke-RestMethod -Method Get -Uri $AdminRoot -Headers $headers).tenantSettings
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
# 3. Find the relevant settings from the live list
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
$targets | Select-Object settingName, title, enabled, canSpecifySecurityGroups, `
    @{ Name = 'EnabledGroups'; Expression = { @(Get-SettingGroups -Setting $_ -PropertyName 'enabledSecurityGroups').Count } } | `
    Format-Table -AutoSize

if ($List) { return }

# --------------------------------------------------------------------------
# 4. Enable whatever is still off
# --------------------------------------------------------------------------
$groupId = $null
if (-not $WholeTenant) {
    $groupId = az ad group list --display-name $SecurityGroup --query '[0].id' -o tsv
    if (-not $groupId) { throw "Security group '$SecurityGroup' not found. Pass -WholeTenant to apply tenant-wide instead." }

    if ($PrincipalObjectId) {
        $isMember = az ad group member check --group $groupId --member-id $PrincipalObjectId --query value -o tsv
        if ($LASTEXITCODE -ne 0 -or $isMember -ne 'true') {
            throw "Principal '$PrincipalObjectId' is not a direct member of '$SecurityGroup'; scoped Fabric settings would not apply to it."
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
        $enabledGroups = @(Get-SettingGroups -Setting $setting -PropertyName 'enabledSecurityGroups')
        if (-not ($enabledGroups | Where-Object { $_.graphId -eq $groupId })) {
            $enabledGroups += [pscustomobject]@{ graphId = $groupId; name = $SecurityGroup }
        }

        $body.enabledSecurityGroups = @($enabledGroups | ForEach-Object {
                @{ graphId = $_.graphId; name = $_.name }
            })
        $body.excludedSecurityGroups = @(Get-SettingGroups -Setting $setting -PropertyName 'excludedSecurityGroups' | `
                Where-Object { $_.graphId -ne $groupId } | ForEach-Object {
                @{ graphId = $_.graphId; name = $_.name }
            })
    }
    elseif ($setting.canSpecifySecurityGroups) {
        $body.enabledSecurityGroups = @()
        $body.excludedSecurityGroups = @()
    }

    try {
        Invoke-RestMethod -Method Post -Uri "$AdminRoot/$($setting.settingName)/update" `
            -Headers $headers -Body ($body | ConvertTo-Json -Depth 6) | Out-Null
        $scopeText = if ($body.ContainsKey('enabledSecurityGroups')) { "scoped to $SecurityGroup" } else { 'tenant-wide' }
        Write-Host "  enabled $($setting.settingName) ($scopeText)"
        $changed++
    }
    catch {
        throw "Could not configure $($setting.settingName): $($_.Exception.Message)"
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

if ($changed -eq 0) {
    Write-Host 'Nothing to change; all required settings already have the requested scope.'
}
else {
    Write-Host ''
    Write-Host "Changed $changed setting(s). Allow up to 15 minutes for propagation, then:"
    Write-Host '  ./scripts/Apply-Workspaces.ps1'
}
