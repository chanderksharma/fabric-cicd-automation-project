<#
.SYNOPSIS
    One-time bootstrap for the Fabric platform foundation.

.DESCRIPTION
    Creates everything Terraform cannot create for itself:
      1. Resource group + storage account + container for remote state
      2. The CI/CD app registration and its service principal
      3. Federated credentials (no client secret is ever created)
      4. Azure RBAC for the service principal

    Run once, by a human with Owner on the subscription and permission to
    create app registrations in Entra ID. Every step is idempotent.

.EXAMPLE
    # Manual lane. No arguments needed: everything defaults, and the app
    # registration and federated credentials are skipped because nothing in
    # this lane authenticates as a service principal.
    ./scripts/bootstrap.ps1

.EXAMPLE
    # GitHub Actions lane.
    ./scripts/bootstrap.ps1 -Lane gh `
        -GitHubOrg chanderksharma -GitHubOrgId 293792156 `
        -GitHubRepo fabric-cicd-automation-project -GitHubRepoId 1340759336
#>
[CmdletBinding()]
param(
    # ml builds a foundation you drive from this machine; gh additionally
    # creates the app registration and federated credentials Actions needs.
    # Lane-specific resources carry the lane in their name, so both can exist
    # in one tenant at the same time.
    [ValidateSet('gh', 'ml')] [string] $Lane = 'ml',
    [string] $GitHubOrg = 'chanderksharma',
    [string] $GitHubOrgId = '',
    [string] $GitHubRepo = 'fabric-cicd-automation-project',
    [string] $GitHubRepoId = '',
    [string] $SubscriptionId,
    [string] $Location = 'centralus',
    # State storage and the perimeter are shared by both lanes: they hold no
    # lane-specific configuration, and duplicating a perimeter doubles the
    # network exceptions to maintain for no isolation gain. Lanes are separated
    # by state key instead.
    [string] $StateResourceGroup = 'rg-terraform-state',
    # Globally unique across Azure. Left empty, the name is read from
    # infra/platform/platform.backend.hcl and confirmed with a prompt.
    [string] $StateStorageAccount = '',
    # One container per lane: <prefix>-gh and <prefix>-ml. The account is shared,
    # the containers are not.
    [string] $ContainerPrefix = 'tfstate',
    # The lane is appended unless you pass a name explicitly.
    [string] $AppName = '',
    # Entra groups are deliberately shared. They describe people, and the same
    # people administer both lanes; a second copy would be two objects to keep
    # in step with no benefit.
    [string] $AdminGroup = 'sg-fabric-platform-admins',
    [string] $EngineerGroup = 'sg-fabric-data-engineers',
    [string] $AnalystGroup = 'sg-fabric-analysts',

    # Humans to place in the platform admin group, by UPN or object ID. A CI run
    # has no signed-in user, so without this nobody gains workspace access.
    [string[]] $PlatformAdminMembers = @(),
    [string] $NspName = 'sec-perimeter',
    # Defaults to the state resource group, so the perimeter is owned and torn
    # down with the thing it protects rather than living in shared infrastructure.
    [string] $NspResourceGroup = '',
    [string] $NspProfile = 'defaultProfile',
    [ValidateSet('Enforced', 'Learning')] [string] $NspAccessMode = 'Enforced',
    # Extra CIDRs allowed inbound, e.g. a CI egress range. The caller's own
    # public IP is detected and added automatically unless -NspNoAutoIp is set.
    [string[]] $NspAllowedIpPrefixes = @(),
    [switch] $NspNoAutoIp,
    # Outbound destinations permitted for resources inside the perimeter. Only
    # relevant once a resource type that initiates outbound calls joins; a
    # storage account does not.
    [string[]] $NspAllowedFqdns = @('app.powerbi.com', 'api.fabric.microsoft.com', 'onelake.dfs.fabric.microsoft.com'),
    [switch] $SkipNsp,
    [switch] $CreateGroups,
    [string] $DefaultBranch = 'main',
    # Used by an automated bootstrap so the seed service principal can create
    # and reach the state container before the permanent OIDC identity exists.
    [string] $CallerObjectId,
    [ValidateSet('User', 'ServicePrincipal')]
    [string] $CallerPrincipalType = 'User',
    # Force the service principal on in the ml lane, for example to hand the
    # same foundation to a pipeline later.
    [switch] $CreateServicePrincipal
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $AppName) { $AppName = "sp-fabric-cicd-$Lane" }

# PowerShell 7.4+ turns any non-zero native exit code into a terminating error
# while ErrorActionPreference is Stop. This script inspects $LASTEXITCODE to
# stay idempotent, so that behaviour has to be off.
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Az {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed: $output"
    }
    return $output
}

# For calls whose failure is expected and benign, such as re-creating a role
# assignment that already exists. Swallows both streams and returns the exit
# code so the caller can decide.
function Invoke-AzQuiet {
    param([Parameter(Mandatory)][string[]] $Arguments)
    & az @Arguments *>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    return $exitCode
}

# ARM PUT with a JSON body. az rest reads the body from a file to avoid the
# quoting differences between shells.
function Invoke-AzRestPut {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][hashtable] $Body
    )
    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile -Value ($Body | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
        Invoke-Az @(
            'rest', '--method', 'PUT',
            '--url', $Url,
            '--headers', 'Content-Type=application/json',
            '--body', "@$tempFile",
            '-o', 'none'
        ) | Out-Null
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv)
}
Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$TenantId = (az account show --query tenantId -o tsv)

Write-Host "==> Subscription : $SubscriptionId"
Write-Host "==> Tenant       : $TenantId"
Write-Host "==> Repository   : $GitHubOrg/$GitHubRepo"

# -----------------------------------------------------------------------------
# 0. Entra security groups
#
# Terraform reads these with azuread_group data sources and never creates them,
# so that membership stays under identity governance. -CreateGroups exists for
# sandbox tenants where no such process is in place yet.
# -----------------------------------------------------------------------------
function Confirm-Group {
    param([string] $Name)

    $oid = az ad group list --display-name $Name --query '[0].id' -o tsv 2>$null
    if ($oid) {
        Write-Host "    exists   $Name  ($oid)"
        return $true
    }
    if (-not $CreateGroups) {
        Write-Host "    MISSING  $Name"
        return $false
    }
    $oid = az ad group create --display-name $Name --mail-nickname $Name --query id -o tsv
    Write-Host "    created  $Name  ($oid)"
    return $true
}

Write-Host '==> Checking Entra security groups'
$groupsOk = $true
foreach ($g in @($AdminGroup, $EngineerGroup, $AnalystGroup)) {
    if (-not (Confirm-Group -Name $g)) { $groupsOk = $false }
}

if ($CreateGroups) {
    # Terraform reads the capacity through the Fabric API, which requires the
    # caller to be a capacity administrator. Membership here is what grants it.
    $signedInOid = az ad signed-in-user show --query id -o tsv
    $adminOid = az ad group list --display-name $AdminGroup --query '[0].id' -o tsv
    if (-not $signedInOid) {
        Write-Host '    caller is not a user; skipping caller group membership'
    }
    elseif ((Invoke-AzQuiet @('ad', 'group', 'member', 'add', '--group', $adminOid, '--member-id', $signedInOid, '-o', 'none')) -eq 0) {
        Write-Host "    added you to $AdminGroup"
    }
    else {
        Write-Host "    (you are already a member of $AdminGroup)"
    }
}
elseif (-not $groupsOk) {
    Write-Host '    Terraform will fail on the azuread_group data sources until these'
    Write-Host '    groups exist. Re-run with -CreateGroups, or create them out of band.'
}

if ($PlatformAdminMembers.Count -gt 0 -and $groupsOk) {
    $adminOid = az ad group list --display-name $AdminGroup --query '[0].id' -o tsv
    foreach ($member in $PlatformAdminMembers) {
        $lookupError = $null
        $memberOid = if ($member -match '^[0-9a-fA-F-]{36}$') {
            $member
        }
        else {
            $found = $null
            $output = & az ad user show --id $member --query id -o tsv 2>&1
            if ($LASTEXITCODE -eq 0) {
                $found = "$(@($output | Where-Object { $_ -is [string] }) | Select-Object -Last 1)".Trim()
            }
            else {
                $global:LASTEXITCODE = 0
                $lookupError = ($output | Out-String).Trim()
            }

            # A sign-in address is not always the userPrincipalName, and
            # az ad user show accepts only the UPN or the object ID.
            if (-not $found) {
                $escaped = $member.Replace("'", "''")
                $output = & az ad user list --filter "userPrincipalName eq '$escaped' or mail eq '$escaped'" --query '[0].id' -o tsv 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $found = "$(@($output | Where-Object { $_ -is [string] }) | Select-Object -Last 1)".Trim()
                }
                else {
                    $global:LASTEXITCODE = 0
                    $lookupError = ($output | Out-String).Trim()
                }
            }
            $found
        }

        if (-not $memberOid) {
            throw @"
Could not resolve '$member' to a user. $lookupError
Reading users needs Microsoft Graph User.Read.All or Directory.Read.All on the
identity running this script. Pass the object ID instead to skip the lookup.
"@
        }

        $isMember = az ad group member check --group $adminOid --member-id $memberOid --query value -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
        if ($isMember -eq 'true') {
            Write-Host "    ($member is already in $AdminGroup)"
            continue
        }

        $addOutput = & az ad group member add --group $adminOid --member-id $memberOid -o none 2>&1
        $addText = ($addOutput | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    added $member to $AdminGroup"
        }
        elseif ($addText -match 'already exist') {
            # The membership check above is unreliable for a service principal,
            # so a duplicate reference is the authoritative 'already a member'.
            $global:LASTEXITCODE = 0
            Write-Host "    ($member is already in $AdminGroup)"
        }
        else {
            $global:LASTEXITCODE = 0
            throw @"
Could not add '$member' to $AdminGroup. $addText
Writing group membership needs Microsoft Graph GroupMember.ReadWrite.All or
Group.ReadWrite.All, admin-consented on the identity running this script.
"@
        }
    }
}

# -----------------------------------------------------------------------------
# 1. Remote state
# -----------------------------------------------------------------------------
# Built by New-StateFoundation.ps1 so the perimeter is defined in exactly one
# place. Two copies would drift, and the perimeter is where drift costs most.
. (Join-Path $PSScriptRoot 'StateAccountHelpers.ps1')

$StateStorageAccount = Resolve-StateStorageAccount -Name $StateStorageAccount -RepoRoot $RepoRoot
$StateContainer = "$ContainerPrefix-$Lane"
$accountStatus = Get-StateStorageAccountStatus -Name $StateStorageAccount

if (-not $accountStatus.Exists -and -not $accountStatus.Available) {
    throw @"
Storage account name '$StateStorageAccount' is already taken by another tenant.
The namespace is global. Choose another name and re-run with
-StateStorageAccount <name>.
"@
}

$needFoundation = $true
if ($accountStatus.Exists) {
    Write-Host "==> State account '$StateStorageAccount' exists in $($accountStatus.ResourceGroup)"
    if (Test-StateContainer -AccountName $StateStorageAccount -ContainerName $StateContainer) {
        Write-Host "    container '$StateContainer' exists; skipping the state foundation"
        $needFoundation = $false
    }
    else {
        Write-Host "    container '$StateContainer' is missing or unreachable"
    }
}
else {
    Write-Host "==> State account '$StateStorageAccount' does not exist"
}

if ($needFoundation) {
    Write-Host '==> Running New-StateFoundation.ps1'
    $foundationArgs = @{
        SubscriptionId       = $SubscriptionId
        Location             = $Location
        ResourceGroup        = $StateResourceGroup
        StorageAccount       = $StateStorageAccount
        ContainerPrefix      = $ContainerPrefix
        Lanes                = @($Lane)
        DefaultLane          = $Lane
        AdminGroup           = $AdminGroup
        CallerObjectId       = $CallerObjectId
        CallerPrincipalType  = $CallerPrincipalType
        NspName              = $NspName
        NspResourceGroup     = $NspResourceGroup
        NspProfile           = $NspProfile
        NspAccessMode        = $NspAccessMode
        NspAllowedIpPrefixes = $NspAllowedIpPrefixes
        NspAllowedFqdns      = $NspAllowedFqdns
        SkipBackendCheck     = $true
    }
    if ($NspNoAutoIp) { $foundationArgs.NspNoAutoIp = $true }
    if ($SkipNsp) { $foundationArgs.SkipNsp = $true }

    & (Join-Path $PSScriptRoot 'New-StateFoundation.ps1') @foundationArgs
}

$StorageAccountId = az storage account show --name $StateStorageAccount --resource-group $StateResourceGroup --query id -o tsv

# -----------------------------------------------------------------------------
# 2. App registration + service principal
# -----------------------------------------------------------------------------
# The ml lane has no automated caller, so it needs no service principal and no
# federated credentials. Creating them anyway would leave an unused identity
# holding Contributor and User Access Administrator on the subscription.
$WantServicePrincipal = ($Lane -eq 'gh') -or $CreateServicePrincipal

$AppId = ''
$SpObjectId = ''

if (-not $WantServicePrincipal) {
    Write-Host '==> Skipping app registration (ml lane runs as you)'
}
else {
    Write-Host "==> Creating app registration '$AppName'"
    $AppId = az ad app list --display-name $AppName --query '[0].appId' -o tsv
    if (-not $AppId) {
        $AppId = az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg --query appId -o tsv
    }

    $SpObjectId = az ad sp list --filter "appId eq '$AppId'" --query '[0].id' -o tsv
    if (-not $SpObjectId) {
        # A just-created app registration is not visible to the service principal
        # endpoint until Entra replicates it.
        $arguments = @('ad', 'sp', 'create', '--id', $AppId, '--query', 'id', '-o', 'tsv')
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $output = & az @arguments 2>&1
            if ($LASTEXITCODE -eq 0) {
                $SpObjectId = "$($output | Where-Object { $_ -is [string] } | Select-Object -Last 1)".Trim()
                break
            }

            # The create can also fail after having succeeded.
            $SpObjectId = az ad sp list --filter "appId eq '$AppId'" --query '[0].id' -o tsv
            if ($SpObjectId) { break }

            $message = $output -join [Environment]::NewLine
            if ($attempt -eq 6 -or $message -notmatch '(?i)does not reference a valid application object|not found|does not exist|temporar|try again') {
                throw "az $($arguments -join ' ') failed: $message"
            }

            $delaySeconds = 5 * $attempt
            Write-Host "    '$AppName' is waiting for Entra propagation; retrying in ${delaySeconds}s"
            Start-Sleep -Seconds $delaySeconds
        }
    }

    # Everything below binds roles to this object id, and az reports a null one
    # as an unrelated parameter binding error.
    if (-not $SpObjectId) {
        throw "Could not resolve the service principal object id for '$AppName'."
    }

    $graphAppId = '00000003-0000-0000-c000-000000000000'
    $directoryReadAllRoleId = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
    $permissionJson = Invoke-Az @('ad', 'app', 'permission', 'list', '--id', $AppId, '-o', 'json')
    $permissions = ($permissionJson -join [Environment]::NewLine) | ConvertFrom-Json
    $hasDirectoryRead = $permissions |
        Where-Object { $_.resourceAppId -eq $graphAppId } |
        ForEach-Object { $_.resourceAccess } |
        Where-Object { $_.id -eq $directoryReadAllRoleId -and $_.type -eq 'Role' }
    if (-not $hasDirectoryRead) {
        Invoke-Az @(
            'ad', 'app', 'permission', 'add',
            '--id', $AppId,
            '--api', $graphAppId,
            '--api-permissions', "$directoryReadAllRoleId=Role",
            '-o', 'none'
        ) | Out-Null
        Write-Host '    added Microsoft Graph Directory.Read.All application permission'
    }

    # Requesting the permission does not grant it. Without consent the directory
    # stays unreadable and Terraform's group lookups fail with 403.
    $grantedRoles = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments" `
        --query "length(value[?appRoleId=='$directoryReadAllRoleId'])" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; $grantedRoles = '0' }

    if ($grantedRoles -eq '0') {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $output = & az ad app permission admin-consent --id $AppId 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host '    granted admin consent for Directory.Read.All'
                break
            }
            $global:LASTEXITCODE = 0

            $message = $output -join [Environment]::NewLine
            if ($attempt -eq 6 -or $message -notmatch '(?i)does not exist|not found|temporar|try again|propagat') {
                throw "Admin consent failed for '$AppName' ($AppId): $message. Grant Microsoft Graph Directory.Read.All in Entra ID > App registrations > API permissions, then re-run."
            }

            $delaySeconds = 5 * $attempt
            Write-Host "    waiting for Entra propagation before consenting; retrying in ${delaySeconds}s"
            Start-Sleep -Seconds $delaySeconds
        }
    }
    else {
        Write-Host '    Directory.Read.All is already consented'
    }

    Write-Host "    appId (client id)     : $AppId"
    Write-Host "    service principal oid : $SpObjectId"

    $adminOid = az ad group list --display-name $AdminGroup --query '[0].id' -o tsv
    if ($adminOid) {
        # Checking first, because a refused write and an existing membership are
        # not the same thing and used to report identically.
        $isMember = az ad group member check --group $adminOid --member-id $SpObjectId --query value -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }

        if ($isMember -eq 'true') {
            Write-Host "    (deployment principal is already in $AdminGroup)"
        }
        else {
            $addOutput = & az ad group member add --group $adminOid --member-id $SpObjectId -o none 2>&1
            $addText = ($addOutput | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    added deployment principal to $AdminGroup"
            }
            elseif ($addText -match 'already exist') {
                $global:LASTEXITCODE = 0
                Write-Host "    (deployment principal is already in $AdminGroup)"
            }
            else {
                $global:LASTEXITCODE = 0
                Write-Host "    WARNING could not add the deployment principal to ${AdminGroup}: $addText" -ForegroundColor Yellow
            }
        }
    }
}

# -----------------------------------------------------------------------------
# 3. Federated credentials
# -----------------------------------------------------------------------------
function Add-FederatedCredential {
    param([string] $Name, [string] $Subject)

    $issuer = 'https://token.actions.githubusercontent.com'
    $audience = 'api://AzureADTokenExchange'

    function Get-ExistingCredential {
        $output = & az ad app federated-credential show `
            --id $AppId `
            --federated-credential-id $Name `
            -o json 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    }

    function Test-ExpectedCredential {
        param($Credential)
        return $null -ne $Credential `
            -and $Credential.issuer -eq $issuer `
            -and $Credential.subject -eq $Subject `
            -and @($Credential.audiences).Count -eq 1 `
            -and $Credential.audiences[0] -eq $audience
    }

    $existing = Get-ExistingCredential
    if (Test-ExpectedCredential -Credential $existing) {
        Write-Host "    federated credential '$Name' already matches"
        return
    }
    if ($existing) {
        Write-Host "    replacing drifted federated credential '$Name'"
        Invoke-Az @(
            'ad', 'app', 'federated-credential', 'delete',
            '--id', $AppId,
            '--federated-credential-id', $Name
        ) | Out-Null
    }

    $parameters = @{
        name        = $Name
        issuer      = $issuer
        subject     = $Subject
        description = "GitHub Actions OIDC for $Subject"
        audiences   = @($audience)
    } | ConvertTo-Json -Compress

    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile -Value $parameters -Encoding utf8
        $arguments = @(
            'ad', 'app', 'federated-credential', 'create',
            '--id', $AppId,
            '--parameters', "@$tempFile",
            '-o', 'none'
        )
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $output = & az @arguments 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    added federated credential '$Name' -> $Subject"
                return
            }

            $existing = Get-ExistingCredential
            if (Test-ExpectedCredential -Credential $existing) {
                Write-Host "    federated credential '$Name' exists after a delayed response"
                return
            }

            $message = $output -join [Environment]::NewLine
            if ($attempt -eq 6 -or $message -notmatch '(?i)already exists|duplicate values|conflict|concurrent requests|temporar|wait briefly') {
                throw "az $($arguments -join ' ') failed: $message"
            }

            $delaySeconds = 5 * $attempt
            Write-Host "    '$Name' is waiting for Entra propagation; retrying in ${delaySeconds}s"
            Start-Sleep -Seconds $delaySeconds
        }
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $WantServicePrincipal) {
    Write-Host '==> Skipping federated credentials (no service principal in this lane)'
}
else {
    if (-not $GitHubOrgId -or -not $GitHubRepoId) {
        throw 'GitHubOrgId and GitHubRepoId are required for immutable GitHub OIDC subjects.'
    }

    $repositorySubject = "${GitHubOrg}@${GitHubOrgId}/${GitHubRepo}@${GitHubRepoId}"
    Write-Host '==> Adding federated credentials'
    Add-FederatedCredential -Name 'gh-env-platform' -Subject "repo:$repositorySubject`:environment:platform"
    Add-FederatedCredential -Name 'gh-env-dev'      -Subject "repo:$repositorySubject`:environment:dev"
    Add-FederatedCredential -Name 'gh-env-test'     -Subject "repo:$repositorySubject`:environment:test"
    Add-FederatedCredential -Name 'gh-env-prod'     -Subject "repo:$repositorySubject`:environment:prod"
    Add-FederatedCredential -Name 'gh-pull-request' -Subject "repo:$repositorySubject`:pull_request"
    Add-FederatedCredential -Name 'gh-branch-main'  -Subject "repo:$repositorySubject`:ref:refs/heads/$DefaultBranch"
}

# -----------------------------------------------------------------------------
# 4. Azure RBAC
# -----------------------------------------------------------------------------
function Add-RoleAssignment {
    param([string] $Role, [string] $Scope)

    $query = "[?principalId=='$SpObjectId' && roleDefinitionName=='$Role'].id | [0]"
    $existing = Invoke-Az @('role', 'assignment', 'list', '--scope', $Scope, '--query', $query, '-o', 'tsv')
    if ($existing) {
        Write-Host "    $Role already assigned at $Scope"
        return
    }

    $arguments = @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $SpObjectId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', $Role,
        '--scope', $Scope,
        '-o', 'none'
    )
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $output = & az @arguments 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    assigned $Role at $Scope"
            return
        }

        $message = $output -join [Environment]::NewLine
        if ($attempt -eq 6 -or $message -notmatch '(?i)principal.*not found|does not exist|conflict|concurrent|temporar|try again') {
            throw "az $($arguments -join ' ') failed: $message"
        }

        $delaySeconds = 10 * $attempt
        Write-Host "    waiting for service principal propagation; retrying $Role in ${delaySeconds}s"
        Start-Sleep -Seconds $delaySeconds
    }
}

if (-not $WantServicePrincipal) {
    Write-Host '==> Skipping service principal RBAC (you already hold Owner)'
}
else {
    Write-Host '==> Assigning Azure RBAC to the service principal'
    Add-RoleAssignment -Role 'Storage Blob Data Contributor' -Scope $StorageAccountId
    # Contributor creates the Fabric capacity resource group; User Access
    # Administrator lets the platform root manage role assignments. Narrow both to a
    # pre-created resource group if subscription-scope grants are not permitted.
    Add-RoleAssignment -Role 'Contributor' -Scope "/subscriptions/$SubscriptionId"
    Add-RoleAssignment -Role 'User Access Administrator' -Scope "/subscriptions/$SubscriptionId"
}

# -----------------------------------------------------------------------------
# 5. Consistency check
# -----------------------------------------------------------------------------
# Storage account names are globally unique, so -StateStorageAccount usually has
# to be overridden. The four committed backend configs do not follow along.
Write-Host '==> Checking the committed backend configs point at this storage account'
$BackendFiles = @(
    'infra/platform/platform.backend.hcl'
    'infra/workspace/envs/dev.backend.hcl'
    'infra/workspace/envs/test.backend.hcl'
    'infra/workspace/envs/prod.backend.hcl'
)

$mismatch = $false
foreach ($file in $BackendFiles) {
    $path = Join-Path $RepoRoot $file
    if (-not (Test-Path $path)) { continue }
    $content = Get-Content $path -Raw
    if ($content -notmatch "(?m)^storage_account_name\s*=\s*""$([regex]::Escape($StateStorageAccount))""") {
        Write-Host "    MISMATCH  $file (storage account)"
        $mismatch = $true
    }
    if ($content -notmatch "(?m)^resource_group_name\s*=\s*""$([regex]::Escape($StateResourceGroup))""") {
        Write-Host "    MISMATCH  $file (resource group)"
        $mismatch = $true
    }
    # The committed files name one lane's container; the other is selected at
    # init. Only flag it when this lane is the one they are supposed to name.
    if ($Lane -eq 'ml' -and $content -notmatch "(?m)^container_name\s*=\s*""$([regex]::Escape($StateContainer))""") {
        Write-Host "    MISMATCH  $file (container)"
        $mismatch = $true
    }
}

if ($mismatch) {
    Write-Host @"

    The files above reference a different account, resource group or container.
    terraform init will fail until they are updated to:

      resource_group_name  = "$StateResourceGroup"
      storage_account_name = "$StateStorageAccount"
      container_name       = "$ContainerPrefix-ml"

    Or run:  ./scripts/New-StateFoundation.ps1 -StorageAccount $StateStorageAccount -UpdateBackendConfigs

"@
}
else {
    Write-Host '    all four backend configs match.'
}

Write-Host @"

=============================================================================
Bootstrap complete for the '$Lane' lane. None of the values below are secrets.

  FABRIC_LANE            $Lane
  AZURE_TENANT_ID        $TenantId
  AZURE_SUBSCRIPTION_ID  $SubscriptionId
  AZURE_CLIENT_ID        $(if ($AppId) { $AppId } else { '(none; this lane runs as you)' })
  SP object id           $(if ($SpObjectId) { $SpObjectId } else { '(none; leave FABRIC_CICD_SP_OBJECT_ID empty)' })

State for this lane lives in its own container:
  $StateStorageAccount / $StateContainer
  platform.tfstate, workspace-dev.tfstate, workspace-test.tfstate, workspace-prod.tfstate

Every Fabric and Azure resource this lane creates carries the '-$Lane' suffix,
so the other lane can be built alongside it without collision.

Next steps: docs/setup-$(if ($Lane -eq 'gh') { 'github-actions' } else { 'manual-cli' }).md
Tenant settings and Entra group creation are manual runbooks - Terraform
cannot manage either.
=============================================================================
"@
