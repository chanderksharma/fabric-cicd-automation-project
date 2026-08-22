<#
.SYNOPSIS
    One-time creation of the Terraform state foundation: storage account,
    per-lane containers, and the network security perimeter that fronts them.

.DESCRIPTION
    This is the only part of the platform Terraform cannot create for itself,
    because Terraform needs somewhere to put its state before it can run.

    Creates, in the one order that works:

      1. Resource group for state
      2. Storage account (no shared keys, TLS 1.2, versioning, soft delete)
      3. Network security perimeter, profile, access rules and association
      4. publicNetworkAccess = SecuredByPerimeter, which is only accepted
         once the association exists
      5. One container per lane: <prefix>-gh, <prefix>-ml
      6. CanNotDelete lock on the resource group

    The account and perimeter are shared; the containers are not. A container
    per lane means the two estates cannot see each other's state at all, which
    is a stronger boundary than a shared container with different blob names:
    an RBAC assignment can be scoped to one container, a blob prefix cannot.

    Every step is idempotent. Re-run it after adding a lane or changing the
    allowed IP list.

.EXAMPLE
    # Everything defaults except the globally unique account name.
    ./scripts/New-StateFoundation.ps1 -StorageAccount stcontosofabtfstate

.EXAMPLE
    # Create it and point the committed backend configs at it.
    ./scripts/New-StateFoundation.ps1 -StorageAccount stmyorgtfstate -UpdateBackendConfigs

.EXAMPLE
    ./scripts/New-StateFoundation.ps1 -StorageAccount stmyorgtfstate -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SubscriptionId,
    [string] $Location = 'centralus',

    [string] $ResourceGroup = 'rg-terraform-state',

    # Globally unique across Azure. Left empty, the name is read from
    # infra/platform/platform.backend.hcl and confirmed with a prompt.
    [string] $StorageAccount = '',

    [ValidateSet('Standard_LRS', 'Standard_ZRS', 'Standard_GRS')]
    [string] $Sku = 'Standard_ZRS',

    # One container is created per lane, named <ContainerPrefix>-<lane>.
    [string[]] $Lanes = @('gh', 'ml'),
    [string] $ContainerPrefix = 'tfstate',

    # Granted Storage Blob Data Contributor so more than one person can run
    # Terraform locally.
    [string] $AdminGroup = 'sg-fabric-platform-admins',

    # Explicit caller identity for non-interactive runs. Local runs discover
    # the signed-in user; CI passes the seed service principal object ID.
    [string] $CallerObjectId,
    [ValidateSet('User', 'ServicePrincipal')]
    [string] $CallerPrincipalType = 'User',

    [string] $NspName = 'az-nw-security-perimeter',
    [string] $NspResourceGroup = '',
    [string] $NspProfile = 'defaultProfile',
    [ValidateSet('Enforced', 'Learning')] [string] $NspAccessMode = 'Enforced',

    # Extra CIDRs allowed inbound, e.g. a self-hosted runner subnet. The
    # caller's own public IP is added automatically unless -NspNoAutoIp is set.
    [string[]] $NspAllowedIpPrefixes = @(),
    [switch] $NspNoAutoIp,

    [string[]] $NspAllowedFqdns = @('app.powerbi.com', 'api.fabric.microsoft.com', 'onelake.dfs.fabric.microsoft.com'),

    [switch] $SkipNsp,
    [switch] $SkipLock,

    # Rewrite the four committed *.backend.hcl files to match what this run
    # created. Off by default: they are source, not output.
    [switch] $UpdateBackendConfigs,

    # For callers that run their own check, such as bootstrap.ps1.
    [switch] $SkipBackendCheck,

    # Lane whose container the committed backend configs should name. The other
    # lane is selected with -backend-config="container_name=..." at init.
    [string] $DefaultLane = 'ml'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script inspects $LASTEXITCODE to stay idempotent, so PowerShell 7.4+ must
# not turn a non-zero native exit code into a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockName = 'terraform-state-protect'
if (-not $NspResourceGroup) { $NspResourceGroup = $ResourceGroup }
if ($DefaultLane -notin $Lanes) { throw "-DefaultLane '$DefaultLane' is not in -Lanes ($($Lanes -join ', '))." }

. (Join-Path $PSScriptRoot 'StateAccountHelpers.ps1')

function Invoke-Az {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed: $output" }
    return $output
}

function Invoke-AzQuiet {
    param([Parameter(Mandatory)][string[]] $Arguments)
    & az @Arguments *>&1 | Out-Null
    return $LASTEXITCODE
}

# ARM PUT with a JSON body, read from a file to sidestep shell quoting.
function Invoke-AzRestPut {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][hashtable] $Body
    )
    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile -Value ($Body | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
        Invoke-Az @('rest', '--method', 'PUT', '--url', $Url, '--headers', 'Content-Type=application/json', '--body', "@$tempFile", '-o', 'none') | Out-Null
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
$account = & az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw 'Not signed in. Run `az login` first.' }

if ($SubscriptionId) { Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null }
else { $SubscriptionId = $account.id }

$StorageAccount = Resolve-StateStorageAccount -Name $StorageAccount -RepoRoot $RepoRoot
$status = Get-StateStorageAccountStatus -Name $StorageAccount

if (-not $status.Exists -and -not $status.Available) {
    throw @"
Storage account name '$StorageAccount' is already taken by another tenant.

The namespace is global, so the name has to be unique across all of Azure, not
just this subscription. Choose another and re-run:

    ./scripts/New-StateFoundation.ps1 -StorageAccount <name> -UpdateBackendConfigs
"@
}

if ($status.Exists -and $status.ResourceGroup -ne $ResourceGroup) {
    throw @"
Storage account '$StorageAccount' already exists in resource group
'$($status.ResourceGroup)', but this run targets '$ResourceGroup'.

Either point at the existing group (-ResourceGroup $($status.ResourceGroup)) or
choose a different account name.
"@
}

$containers = $Lanes | ForEach-Object { "$ContainerPrefix-$_" }

Write-Host "Subscription : $($account.name) ($SubscriptionId)"
Write-Host "Tenant       : $($account.tenantId)"
Write-Host "Location     : $Location"
Write-Host "Account      : $StorageAccount $(if ($status.Exists) { '(exists; will be reused)' } else { '(will be created)' })"
Write-Host "Containers   : $($containers -join ', ')"
Write-Host ''

# -----------------------------------------------------------------------------
# 1. Resource group
# -----------------------------------------------------------------------------
Write-Host '==> Creating the state resource group'
if ($PSCmdlet.ShouldProcess($ResourceGroup, 'create resource group')) {
    Invoke-Az @(
        'group', 'create',
        '--name', $ResourceGroup,
        '--location', $Location,
        '--tags', 'managed-by=new-state-foundation', 'purpose=terraform-state',
        '-o', 'none'
    ) | Out-Null
}

# -----------------------------------------------------------------------------
# 2. Storage account
# -----------------------------------------------------------------------------
# A storage account cannot change region in place. Catch the mismatch here
# rather than letting the create call fail with a generic conflict.
if ($status.Exists -and $status.Location -ne $Location) {
    throw @"
Storage account '$StorageAccount' already exists in '$($status.Location)', but
this run targets '$Location'. A storage account cannot be moved between regions.

Either keep the existing region (-Location $($status.Location)), or delete the
account first. Deleting requires removing the '$LockName' lock, and destroys all
Terraform state in it:

    az lock delete --name $LockName --resource-group $ResourceGroup
    az group delete --name $ResourceGroup --yes
"@
}

if ($status.Exists) {
    Write-Host "==> Reusing the existing storage account '$StorageAccount'"
}
elseif ($PSCmdlet.ShouldProcess($StorageAccount, 'create storage account')) {
    Write-Host '==> Creating the state storage account'
    Invoke-Az @(
        'storage', 'account', 'create',
        '--name', $StorageAccount,
        '--resource-group', $ResourceGroup,
        '--location', $Location,
        '--sku', $Sku,
        '--kind', 'StorageV2',
        '--min-tls-version', 'TLS1_2',
        '--https-only', 'true',
        '--allow-blob-public-access', 'false',
        # Shared keys off forces Entra auth, which is what makes a scoped RBAC
        # assignment per container meaningful.
        '--allow-shared-key-access', 'false',
        # publicNetworkAccess is deliberately not set here. Governance policy
        # rewrites it, and reachability comes from the perimeter association
        # below rather than from public access.
        '--tags', 'managed-by=new-state-foundation', 'purpose=terraform-state',
        '-o', 'none'
    ) | Out-Null
}

if ($PSCmdlet.ShouldProcess($StorageAccount, 'enable versioning and soft delete')) {
    Write-Host '==> Enabling blob versioning and soft delete'
    Invoke-Az @(
        'storage', 'account', 'blob-service-properties', 'update',
        '--account-name', $StorageAccount,
        '--resource-group', $ResourceGroup,
        '--enable-versioning', 'true',
        '--enable-delete-retention', 'true',
        '--delete-retention-days', '30',
        '--enable-container-delete-retention', 'true',
        '--container-delete-retention-days', '30',
        '-o', 'none'
    ) | Out-Null
}

$StorageAccountId = az storage account show --name $StorageAccount --resource-group $ResourceGroup --query id -o tsv 2>$null

# -----------------------------------------------------------------------------
# 3. Data-plane RBAC
# -----------------------------------------------------------------------------
if ($StorageAccountId) {
    Write-Host '==> Granting Storage Blob Data Contributor'

    if (-not $CallerObjectId) {
        $CallerObjectId = az ad signed-in-user show --query id -o tsv 2>$null
    }
    if ($CallerObjectId -and $PSCmdlet.ShouldProcess('current caller', 'grant Storage Blob Data Contributor')) {
        if ((Invoke-AzQuiet @('role', 'assignment', 'create', '--assignee-object-id', $CallerObjectId, '--assignee-principal-type', $CallerPrincipalType, '--role', 'Storage Blob Data Contributor', '--scope', $StorageAccountId, '-o', 'none')) -ne 0) {
            Write-Host '    (current caller already has it)'
        }
        else {
            Write-Host "    granted to current $CallerPrincipalType"
        }
    }

    # Without this, only the person who ran this script can run Terraform locally.
    $adminGroupOid = az ad group list --display-name $AdminGroup --query '[0].id' -o tsv 2>$null
    if (-not $adminGroupOid) {
        Write-Host "    group '$AdminGroup' not found; create it and re-run so other"
        Write-Host '    engineers can run Terraform against shared state.'
    }
    elseif ($PSCmdlet.ShouldProcess($AdminGroup, 'grant Storage Blob Data Contributor')) {
        if ((Invoke-AzQuiet @('role', 'assignment', 'create', '--assignee-object-id', $adminGroupOid, '--assignee-principal-type', 'Group', '--role', 'Storage Blob Data Contributor', '--scope', $StorageAccountId, '-o', 'none')) -ne 0) {
            Write-Host "    ('$AdminGroup' already has it)"
        }
        else {
            Write-Host "    granted to '$AdminGroup'"
        }
    }
}

# -----------------------------------------------------------------------------
# 4. Network security perimeter
#
# Must run BEFORE the containers are created. Governance forces the account to
# SecuredByPerimeter, which means it is unreachable until it belongs to a
# perimeter, so the association is what makes the data plane usable rather than
# an afterthought.
# -----------------------------------------------------------------------------
$effectiveAccess = az storage account show --name $StorageAccount --resource-group $ResourceGroup --query publicNetworkAccess -o tsv 2>$null

if ($SkipNsp) {
    Write-Host '==> Skipping the network security perimeter (-SkipNsp)'
}
elseif ($PSCmdlet.ShouldProcess($NspName, 'create network security perimeter')) {
    $nspApi = '2023-08-01-preview'
    $nspId = "/subscriptions/$SubscriptionId/resourceGroups/$NspResourceGroup/providers/Microsoft.Network/networkSecurityPerimeters/$NspName"
    $nspUrlBase = "https://management.azure.com$nspId"

    Write-Host "==> Creating perimeter '$NspName' in $NspResourceGroup"
    Invoke-AzRestPut -Url "$($nspUrlBase)?api-version=$nspApi" -Body @{
        location   = $Location
        properties = @{}
        tags       = @{ 'managed-by' = 'new-state-foundation'; 'purpose' = 'terraform-state' }
    }

    Write-Host "    profile '$NspProfile'"
    Invoke-AzRestPut -Url "$nspUrlBase/profiles/$($NspProfile)?api-version=$nspApi" -Body @{ properties = @{} }

    # Inbound from any resource in this subscription. This is what lets a
    # self-hosted CI runner on Azure reach the state account without an IP rule.
    Write-Host '    rule: inbound-subscription'
    Invoke-AzRestPut -Url "$nspUrlBase/profiles/$NspProfile/accessRules/inbound-subscription?api-version=$nspApi" -Body @{
        properties = @{
            direction     = 'Inbound'
            subscriptions = @(@{ id = "/subscriptions/$SubscriptionId" })
        }
    }

    $ipPrefixes = @($NspAllowedIpPrefixes)
    if (-not $NspNoAutoIp) {
        try {
            $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
            $ipPrefixes += "$myIp/32"
            Write-Host "    detected public IP $myIp"
        }
        catch {
            Write-Warning 'Could not detect the public IP. Pass -NspAllowedIpPrefixes to allow this machine.'
        }
    }
    $ipPrefixes = @($ipPrefixes | Where-Object { $_ } | Select-Object -Unique)

    # One rule per prefix rather than a single rule holding all of them.
    # Rewriting an existing rule restarts perimeter propagation and locks out
    # whoever was already allowed, for several minutes.
    foreach ($prefix in $ipPrefixes) {
        $ruleName = 'inbound-ip-' + ($prefix -replace '[./]', '-')
        Write-Host "    rule: $ruleName ($prefix)"
        Invoke-AzRestPut -Url "$nspUrlBase/profiles/$NspProfile/accessRules/$($ruleName)?api-version=$nspApi" -Body @{
            properties = @{
                direction       = 'Inbound'
                addressPrefixes = @($prefix)
            }
        }
    }

    if ($NspAllowedFqdns) {
        Write-Host "    rule: outbound-fqdn ($($NspAllowedFqdns -join ', '))"
        Invoke-AzRestPut -Url "$nspUrlBase/profiles/$NspProfile/accessRules/outbound-fqdn?api-version=$nspApi" -Body @{
            properties = @{
                direction                 = 'Outbound'
                fullyQualifiedDomainNames = @($NspAllowedFqdns)
            }
        }
    }

    Write-Host "==> Associating the storage account with '$NspName'"
    Invoke-AzRestPut -Url "$nspUrlBase/resourceAssociations/assoc-$($StorageAccount)?api-version=$nspApi" -Body @{
        properties = @{
            privateLinkResource = @{ id = $StorageAccountId }
            profile             = @{ id = "$nspId/profiles/$NspProfile" }
            accessMode          = $NspAccessMode
        }
    }
    Write-Host "    associated in $NspAccessMode mode"

    # Governance creates the account with publicNetworkAccess=Disabled, which
    # rejects all public traffic before perimeter rules are ever evaluated.
    # Associating a perimeter does not flip it, so set it explicitly - and only
    # now, because the value is rejected until an association exists.
    Write-Host '    setting publicNetworkAccess to SecuredByPerimeter'
    Invoke-Az @(
        'storage', 'account', 'update',
        '--name', $StorageAccount,
        '--resource-group', $ResourceGroup,
        '--public-network-access', 'SecuredByPerimeter',
        '-o', 'none'
    ) | Out-Null

    $effectiveAccess = az storage account show --name $StorageAccount --resource-group $ResourceGroup --query publicNetworkAccess -o tsv 2>$null
    Write-Host "    publicNetworkAccess is now '$effectiveAccess'"
    if ($effectiveAccess -ne 'SecuredByPerimeter') {
        Write-Warning "Expected 'SecuredByPerimeter' but got '$effectiveAccess'. Policy is overriding the value and the account will stay unreachable."
    }
}

# -----------------------------------------------------------------------------
# 5. One container per lane
# -----------------------------------------------------------------------------
# Three things are eventually consistent here: RBAC propagation to the data
# plane, the perimeter association, and the perimeter access rules. The last is
# the slowest, so the first container may take several minutes. Once one
# succeeds the rest are immediate.
Write-Host '==> Creating one state container per lane'

foreach ($container in $containers) {
    if (-not $PSCmdlet.ShouldProcess($container, 'create container')) { continue }

    $created = $false
    foreach ($attempt in 1..20) {
        $output = & az storage container create --name $container --account-name $StorageAccount --auth-mode login -o none 2>&1
        if ($LASTEXITCODE -eq 0) {
            $created = $true
            Write-Host "    $container (attempt $attempt)"
            break
        }

        $text = "$output"
        # Storage answers a blocked data plane with ResourceNotFound rather than
        # 403, so an account created moments ago looks absent until the perimeter
        # association propagates.
        if ($text -match 'blocked by network rules|public network access|not authorized to perform this operation using this permission|specified resource does not exist|ResourceNotFound') {
            Write-Host "    ${container}: attempt ${attempt}/20 blocked by network or RBAC, retrying in 20s"
            Start-Sleep -Seconds 20
        }
        else {
            throw "az storage container create failed for '$container': $text"
        }
    }

    if (-not $created) {
        throw @"
Could not create container '$container' in '$StorageAccount'.
publicNetworkAccess is '$effectiveAccess'.

The account is inside perimeter '$NspName' but this client cannot reach it. Add
an inbound access rule to profile '$NspProfile' covering your network, run from
inside the perimeter, or re-run with -NspAccessMode Learning while access rules
are worked out.

To add just this machine later:  ./scripts/Grant-MyIpToPerimeter.ps1
"@
    }
}

# -----------------------------------------------------------------------------
# 6. Lock
# -----------------------------------------------------------------------------
# Versioning and soft delete cover accidental blob overwrites; the lock covers
# accidental deletion of the account itself.
if ($SkipLock) {
    Write-Host '==> Skipping the resource group lock (-SkipLock)'
}
elseif ($PSCmdlet.ShouldProcess($ResourceGroup, 'apply CanNotDelete lock')) {
    Write-Host '==> Locking the state resource group against deletion'
    if ((Invoke-AzQuiet @('lock', 'create', '--name', $LockName, '--lock-type', 'CanNotDelete', '--resource-group', $ResourceGroup, '--notes', 'Terraform state. Remove only during a deliberate teardown.', '-o', 'none')) -ne 0) {
        Write-Host '    (lock already exists)'
    }
    else {
        Write-Host "    applied '$LockName'"
    }
}

# -----------------------------------------------------------------------------
# 7. Backend configs
# -----------------------------------------------------------------------------
$backendFiles = @(
    'infra/platform/platform.backend.hcl'
    'infra/workspace/envs/dev.backend.hcl'
    'infra/workspace/envs/test.backend.hcl'
    'infra/workspace/envs/prod.backend.hcl'
)
$defaultContainer = "$ContainerPrefix-$DefaultLane"

if ($UpdateBackendConfigs) {
    Write-Host "==> Pointing the committed backend configs at '$defaultContainer'"
    foreach ($file in $backendFiles) {
        $path = Join-Path $RepoRoot $file
        if (-not (Test-Path $path)) { continue }
        if (-not $PSCmdlet.ShouldProcess($file, 'rewrite backend config')) { continue }

        $content = Get-Content $path -Raw
        $content = $content -replace '(?m)^(resource_group_name\s*=\s*).*$', "`${1}`"$ResourceGroup`""
        $content = $content -replace '(?m)^(storage_account_name\s*=\s*).*$', "`${1}`"$StorageAccount`""
        $content = $content -replace '(?m)^(container_name\s*=\s*).*$', "`${1}`"$defaultContainer`""
        Set-Content -Path $path -Value $content -NoNewline -Encoding utf8
        Write-Host "    updated $file"
    }
}
else {
    Write-Host '==> Checking the committed backend configs'
    if ($SkipBackendCheck) {
        Write-Host '    skipped'
    }
    else {
        $mismatch = $false
        foreach ($file in $backendFiles) {
            $path = Join-Path $RepoRoot $file
            if (-not (Test-Path $path)) { continue }
            $content = Get-Content $path -Raw
            foreach ($pair in @(
                    @{ Key = 'resource_group_name'; Value = $ResourceGroup },
                    @{ Key = 'storage_account_name'; Value = $StorageAccount },
                    @{ Key = 'container_name'; Value = $defaultContainer }
                )) {
                if ($content -notmatch "(?m)^$($pair.Key)\s*=\s*""$([regex]::Escape($pair.Value))""") {
                    Write-Host "    MISMATCH  $file -> $($pair.Key)"
                    $mismatch = $true
                }
            }
        }
        if ($mismatch) {
            Write-Host '    Re-run with -UpdateBackendConfigs to fix them automatically.'
        }
        else {
            Write-Host '    all four match.'
        }
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
$lines = foreach ($lane in $Lanes) {
    $marker = if ($lane -eq $DefaultLane) { '  <- named in the committed backend configs' } else { '' }
    "  $lane -> $ContainerPrefix-$lane$marker"
}

Write-Host @"

=============================================================================
State foundation ready.

  Resource group   $ResourceGroup
  Storage account  $StorageAccount
  Perimeter        $(if ($SkipNsp) { '(skipped)' } else { "$NspName / $NspProfile ($NspAccessMode)" })

Containers:
$($lines -join "`n")

The other lane is selected at init, not by a second set of files:

  terraform init -reconfigure ``
      -backend-config=platform.backend.hcl ``
      -backend-config="container_name=$ContainerPrefix-<lane>"

Next: ./scripts/bootstrap.ps1 -Lane <lane>
=============================================================================
"@
