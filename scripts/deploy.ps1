[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [string]$CsvPath = (Join-Path $PSScriptRoot '..\data\users.example.csv'),

    [ValidateSet('Create', 'Existing')]
    [string]$IdentityMode = 'Create',

    [string]$TenantDomain,

    [string]$Location = 'switzerlandnorth',

    [string[]]$DeveloperLocations = @('francecentral', 'norwayeast'),

    [string]$AllowedSshCidr,

    [string]$SshKeyPath = (Join-Path $HOME '.ssh\techsprint_azure_ed25519'),

    [switch]$SkipWhatIf,

    [switch]$ValidationOnly,

    [ValidateRange(15, 120)]
    [int]$BootstrapTimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$GeneratedDirectory = Join-Path $ProjectRoot 'generated'
$OutputDirectory = Join-Path $ProjectRoot 'output'
$TemplatePath = Join-Path $ProjectRoot 'main.bicep'
$ParameterPath = Join-Path $GeneratedDirectory 'main.parameters.json'
$CompiledTemplatePath = Join-Path $GeneratedDirectory 'main.json'
$StatePath = Join-Path $GeneratedDirectory 'deployment-state.json'
$SecretPath = Join-Path $OutputDirectory 'deployment-secrets.json'
$InitialPasswordPath = Join-Path $OutputDirectory 'initial-user-passwords.csv'
$BootstrapDiagnosticsPath = Join-Path $OutputDirectory 'bootstrap-diagnostics.json'
$TotalPhases = 10

New-Item -ItemType Directory -Force -Path $GeneratedDirectory, $OutputDirectory | Out-Null
if (Test-Path $InitialPasswordPath) {
    Remove-Item -LiteralPath $InitialPasswordPath -Force
}

function Write-Phase {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-Host ''
    Write-Host "[$Number/$TotalPhases] $Message" -ForegroundColor Cyan
}

function Format-Elapsed {
    param([Parameter(Mandatory = $true)][TimeSpan]$Elapsed)
    return '{0:00}:{1:00}:{2:00}' -f [int]$Elapsed.TotalHours, $Elapsed.Minutes, $Elapsed.Seconds
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Nedostaje naredba '$Name'. Instalirajte alat i ponovite deployment."
    }
}

function Invoke-Az {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $result = & az @Arguments --only-show-errors 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Azure CLI naredba nije uspjela: az $($Arguments -join ' ')`n$($result -join [Environment]::NewLine)"
    }

    [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = ($result -join [Environment]::NewLine).Trim()
    }
}

function Get-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $response = Invoke-Az -Arguments ($Arguments + @('--output', 'json'))
    if ([string]::IsNullOrWhiteSpace($response.Output)) {
        return $null
    }
    return $response.Output | ConvertFrom-Json -Depth 100
}

function Wait-SubscriptionDeployment {
    param(
        [Parameter(Mandatory = $true)][string]$DeploymentName,
        [ValidateRange(15, 180)][int]$TimeoutMinutes = 120
    )

    $started = Get-Date
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $lastLine = ''
    $lastPrintedAt = [DateTime]::MinValue
    $deploymentStatus = $null

    while ((Get-Date) -lt $deadline) {
        $show = Invoke-Az -Arguments @('deployment', 'sub', 'show', '--name', $DeploymentName, '--output', 'json') -AllowFailure
        if ($show.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($show.Output)) {
            Start-Sleep -Seconds 10
            continue
        }

        $deploymentStatus = $show.Output | ConvertFrom-Json -Depth 100
        $state = [string]$deploymentStatus.properties.provisioningState
        $activeNames = @()
        try {
            $operations = @(Get-AzJson -Arguments @('deployment', 'operation', 'sub', 'list', '--name', $DeploymentName))
            $activeNames = @($operations | Where-Object {
                $_.properties.provisioningState -in @('Accepted', 'Running')
            } | ForEach-Object {
                [string]$_.properties.targetResource.resourceName
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }
        catch {
            $activeNames = @()
        }

        $activeText = if ($activeNames.Count -gt 0) { $activeNames -join ', ' } else { 'Azure obraduje resurse' }
        $elapsedText = Format-Elapsed -Elapsed ((Get-Date) - $started)
        $line = "$state | $activeText"
        if ($line -ne $lastLine -or ((Get-Date) - $lastPrintedAt).TotalSeconds -ge 60) {
            Write-Host "  [Azure $elapsedText] $line"
            $lastLine = $line
            $lastPrintedAt = Get-Date
        }

        if ($state -in @('Succeeded', 'Failed', 'Canceled')) {
            break
        }
        Start-Sleep -Seconds 20
    }

    if ($null -eq $deploymentStatus) {
        throw "Nije moguce procitati stanje deploymenta '$DeploymentName'."
    }
    $finalState = [string]$deploymentStatus.properties.provisioningState
    if ($finalState -ne 'Succeeded') {
        $errorText = if ($deploymentStatus.properties.PSObject.Properties.Name -contains 'error') {
            [string]$deploymentStatus.properties.error.message
        }
        else {
            'Azure nije vratio detalj pogreske.'
        }
        throw "Azure deployment '$DeploymentName' zavrsio je stanjem '$finalState'. $errorText"
    }
    return $deploymentStatus
}

function Get-AppBootstrapStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$VmName
    )

    $statusScript = @'
state=RUNNING
if [ -f /var/lib/techsprint/app-ready ] && grep -qx 3 /var/lib/techsprint/app-bootstrap-version 2>/dev/null; then
  state=READY
elif [ -f /var/lib/techsprint/app-error ]; then
  state=FAILED
fi
stage=$(cat /var/lib/techsprint/app-stage 2>/dev/null || echo "VM se pokrece")
error=$(tail -n 1 /var/lib/techsprint/app-error 2>/dev/null || true)
printf 'STATE=%s\nSTAGE=%s\nERROR=%s\n' "$state" "$stage" "$error"
'@

    $response = Invoke-Az -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroup,
        '--name', $VmName,
        '--command-id', 'RunShellScript',
        '--scripts', $statusScript,
        '--query', 'value[0].message',
        '--output', 'tsv'
    ) -AllowFailure

    if ($response.ExitCode -ne 0) {
        return [PSCustomObject]@{
            State  = 'WAITING'
            Stage  = 'cekam Azure VM Agent'
            Error  = ''
            Detail = $response.Output
        }
    }

    $stateMatch = [regex]::Match($response.Output, '(?m)^STATE=(.+)$')
    $stageMatch = [regex]::Match($response.Output, '(?m)^STAGE=(.+)$')
    $errorMatch = [regex]::Match($response.Output, '(?m)^ERROR=(.*)$')
    return [PSCustomObject]@{
        State  = if ($stateMatch.Success) { $stateMatch.Groups[1].Value.Trim() } else { 'RUNNING' }
        Stage  = if ($stageMatch.Success) { $stageMatch.Groups[1].Value.Trim() } else { 'VM se pokrece' }
        Error  = if ($errorMatch.Success) { $errorMatch.Groups[1].Value.Trim() } else { '' }
        Detail = $response.Output
    }
}

function Save-AppBootstrapDiagnostics {
    param([Parameter(Mandatory = $true)][array]$Targets)

    $logScript = 'echo "=== STAGE ==="; cat /var/lib/techsprint/app-stage 2>/dev/null || true; echo "=== ERROR ==="; cat /var/lib/techsprint/app-error 2>/dev/null || true; echo "=== APP LOG ==="; tail -n 160 /var/log/techsprint-app-bootstrap.log 2>/dev/null || true; echo "=== WORKER LOG ==="; tail -n 80 /var/log/techsprint-app-worker.log 2>/dev/null || true; echo "=== CLOUD-INIT ==="; tail -n 80 /var/log/cloud-init-output.log 2>/dev/null || true'
    $diagnostics = @()
    foreach ($target in $Targets) {
        $response = Invoke-Az -Arguments @(
            'vm', 'run-command', 'invoke',
            '--resource-group', $target.ResourceGroup,
            '--name', $target.VmName,
            '--command-id', 'RunShellScript',
            '--scripts', $logScript,
            '--query', 'value[0].message',
            '--output', 'tsv'
        ) -AllowFailure
        $diagnostics += [PSCustomObject]@{
            resourceGroup = $target.ResourceGroup
            vmName        = $target.VmName
            exitCode      = $response.ExitCode
            log           = $response.Output
        }
    }
    $diagnostics | ConvertTo-Json -Depth 20 | Set-Content -Path $BootstrapDiagnosticsPath -Encoding UTF8
}

function Wait-AppBootstrap {
    param(
        [Parameter(Mandatory = $true)][array]$Environments,
        [Parameter(Mandatory = $true)][int]$TimeoutMinutes
    )

    $targets = @()
    foreach ($environment in $Environments) {
        foreach ($vmName in @($environment.appVmNames)) {
            $targets += [PSCustomObject]@{
                ResourceGroup = [string]$environment.resourceGroup
                VmName        = [string]$vmName
            }
        }
    }
    if ($targets.Count -eq 0) {
        throw 'Deployment nije vratio popis Moodle aplikacijskih VM-ova.'
    }

    $started = Get-Date
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $lastStatus = @{}

    while ((Get-Date) -lt $deadline) {
        $readyCount = 0
        foreach ($target in $targets) {
            $status = Get-AppBootstrapStatus -ResourceGroup $target.ResourceGroup -VmName $target.VmName
            $key = "$($target.ResourceGroup)/$($target.VmName)"
            $display = "$($status.State): $($status.Stage)"
            if (-not $lastStatus.ContainsKey($key) -or $lastStatus[$key] -ne $display) {
                $elapsedText = Format-Elapsed -Elapsed ((Get-Date) - $started)
                Write-Host "  [Moodle $elapsedText] $($target.VmName) -> $display"
                $lastStatus[$key] = $display
            }

            if ($status.State -eq 'READY') {
                $readyCount++
            }
            elseif ($status.State -eq 'FAILED') {
                Save-AppBootstrapDiagnostics -Targets $targets
                throw "Bootstrap VM-a '$($target.VmName)' nije uspio u fazi '$($status.Stage)'. $($status.Error) Detaljni log: $BootstrapDiagnosticsPath"
            }
        }

        if ($readyCount -eq $targets.Count) {
            Write-Host "  Sva $readyCount Moodle aplikacijska VM-a su spremna." -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 30
    }

    Save-AppBootstrapDiagnostics -Targets $targets
    throw "Moodle bootstrap nije zavrsio unutar $TimeoutMinutes minuta. Detaljni log: $BootstrapDiagnosticsPath"
}

function ConvertTo-Slug {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }

    $slug = $builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $slug = $slug -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ($slug.Length -gt 18) {
        $slug = $slug.Substring(0, 18).TrimEnd('-')
    }
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw "Vrijednost '$Value' nije moguce pretvoriti u valjani Azure slug."
    }
    return $slug
}

function Test-Ipv4Cidr {
    param([Parameter(Mandatory = $true)][string]$Value)

    $components = $Value.Split('/')
    if ($components.Count -ne 2) {
        return $false
    }
    $octets = $components[0].Split('.')
    $prefix = 0
    if ($octets.Count -ne 4 -or -not [int]::TryParse($components[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) {
        return $false
    }

    [uint64]$addressValue = 0
    foreach ($octetText in $octets) {
        $octet = 0
        if (-not [int]::TryParse($octetText, [ref]$octet) -or $octet -lt 0 -or $octet -gt 255) {
            return $false
        }
        $addressValue = ($addressValue -shl 8) -bor [uint64]$octet
    }

    [uint64]$hostMask = if ($prefix -eq 32) { 0 } else { ([uint64]1 -shl (32 - $prefix)) - 1 }
    return (($addressValue -band $hostMask) -eq 0)
}

function New-LabPassword {
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $special = '!%+_'
    $all = $upper + $lower + $digits + $special
    $characters = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $special[(Get-Random -Maximum $special.Length)]
    )
    1..24 | ForEach-Object {
        $characters += $all[(Get-Random -Maximum $all.Length)]
    }
    return -join ($characters | Sort-Object { Get-Random })
}

function Get-OrCreateUser {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$UserPrincipalName,
        [Parameter(Mandatory = $true)][string]$IdentityMode,
        [string]$Password,
        [string]$ExistingObjectId
    )

    if ($IdentityMode -eq 'Existing' -and -not [string]::IsNullOrWhiteSpace($ExistingObjectId)) {
        $parsedObjectId = [Guid]::Empty
        if (-not [Guid]::TryParse($ExistingObjectId, [ref]$parsedObjectId)) {
            throw "Object ID '$ExistingObjectId' za korisnika '$UserPrincipalName' nije valjani GUID."
        }
        return [PSCustomObject]@{
            id                    = $parsedObjectId.ToString()
            _techsprintCreated    = $false
        }
    }

    $existing = Invoke-Az -Arguments @('ad', 'user', 'show', '--id', $UserPrincipalName, '--output', 'json') -AllowFailure
    if ($existing.ExitCode -eq 0) {
        $existingUser = $existing.Output | ConvertFrom-Json -Depth 20
        $existingUser | Add-Member -NotePropertyName '_techsprintCreated' -NotePropertyValue $false -Force
        return $existingUser
    }

    if ($IdentityMode -eq 'Existing') {
        throw "Nije moguce razrijesiti postojeceg Entra korisnika '$UserPrincipalName'. Ako tenant blokira directory read, upisite njegov Object ID u objectId stupac CSV-a."
    }

    try {
        $createdUser = Get-AzJson -Arguments @(
            'ad', 'user', 'create',
            '--display-name', $DisplayName,
            '--user-principal-name', $UserPrincipalName,
            '--password', $Password,
            '--force-change-password-next-sign-in', 'true'
        )
        $createdUser | Add-Member -NotePropertyName '_techsprintCreated' -NotePropertyValue $true -Force
        return $createdUser
    }
    catch {
        throw "Nije moguce kreirati Entra korisnika '$UserPrincipalName'. Azure for Students racun cesto nema User Administrator pravo u skolskom tenant-u. Zatrazite pravo/testni tenant ili koristite -IdentityMode Existing i upn stupac u CSV-u.`n$($_.Exception.Message)"
    }
}

Write-Phase -Number 1 -Message 'Provjera lokalnih alata i Azure prijave'
Assert-Command -Name 'az'
Assert-Command -Name 'ssh-keygen'

$accountCheck = Invoke-Az -Arguments @('account', 'show', '--output', 'none') -AllowFailure
if ($accountCheck.ExitCode -ne 0) {
    Write-Host 'Otvara se Azure prijava...'
    Invoke-Az -Arguments @('login', '--output', 'none') | Out-Null
}
Invoke-Az -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$account = Get-AzJson -Arguments @('account', 'show')
Write-Host "Aktivna pretplata: $($account.name) [$($account.id)]"

Write-Phase -Number 2 -Message 'Provjera Azure resource providera'
$providers = @(
    'Microsoft.Authorization',
    'Microsoft.Compute',
    'Microsoft.ManagedIdentity',
    'Microsoft.Network',
    'Microsoft.Resources',
    'Microsoft.Storage'
)
foreach ($provider in $providers) {
    $state = (Invoke-Az -Arguments @('provider', 'show', '--namespace', $provider, '--query', 'registrationState', '--output', 'tsv') -AllowFailure).Output
    if ($state.Trim() -ne 'Registered') {
        Invoke-Az -Arguments @('provider', 'register', '--namespace', $provider, '--wait') | Out-Null
    }
}

Write-Phase -Number 3 -Message 'Provjera CSV korisnika i rola'
$resolvedCsvPath = (Resolve-Path $CsvPath).Path
$rows = @(Import-Csv -Path $resolvedCsvPath -Delimiter ';' -Encoding UTF8)
if ($rows.Count -lt 3) {
    throw 'CSV mora sadrzavati najmanje dva developera i jednog DevOps Leada.'
}

$requiredColumns = @('ime', 'prezime', 'rola')
foreach ($column in $requiredColumns) {
    if (-not ($rows[0].PSObject.Properties.Name -contains $column)) {
        throw "CSV nema obavezni stupac '$column'."
    }
}

$preparedRows = foreach ($row in $rows) {
    $role = ([string]$row.rola).Trim().ToLowerInvariant()
    if ($role -notin @('developer', 'devops_lead')) {
        throw "Nepoznata rola '$($row.rola)'. Dopusteno: developer ili devops_lead."
    }
    $firstName = ([string]$row.ime).Trim()
    $lastName = ([string]$row.prezime).Trim()
    if ([string]::IsNullOrWhiteSpace($firstName) -or [string]::IsNullOrWhiteSpace($lastName)) {
        throw 'Ime i prezime ne smiju biti prazni.'
    }

    [PSCustomObject]@{
        FirstName   = $firstName
        LastName    = $lastName
        DisplayName = "$firstName $lastName"
        Role        = $role
        Slug        = ConvertTo-Slug -Value "$firstName-$lastName"
        Upn         = if ($row.PSObject.Properties.Name -contains 'upn') { ([string]$row.upn).Trim() } else { '' }
        ObjectIdInput = if ($row.PSObject.Properties.Name -contains 'objectId') { ([string]$row.objectId).Trim() } else { '' }
    }
}

$duplicateSlugs = $preparedRows | Group-Object Slug | Where-Object Count -gt 1
if ($duplicateSlugs) {
    throw "CSV sadrzava duplikate korisnika/sluga: $($duplicateSlugs.Name -join ', ')"
}

$leadRows = @($preparedRows | Where-Object Role -eq 'devops_lead')
$developerRows = @($preparedRows | Where-Object Role -eq 'developer')
if ($leadRows.Count -ne 1) {
    throw 'CSV mora sadrzavati tocno jednog korisnika s rolom devops_lead.'
}
if ($developerRows.Count -lt 2) {
    throw 'CSV mora sadrzavati najmanje dva developera.'
}
if ($developerRows.Count -gt 28) {
    throw 'Ova adresna shema podrzava najvise 28 developera.'
}
if ($DeveloperLocations.Count -lt $developerRows.Count) {
    throw "Nedostaje developer regija. Broj developera: $($developerRows.Count); navedene regije: $($DeveloperLocations.Count)."
}

if ($IdentityMode -eq 'Create' -and [string]::IsNullOrWhiteSpace($TenantDomain)) {
    $signedInUpn = (Invoke-Az -Arguments @('ad', 'signed-in-user', 'show', '--query', 'userPrincipalName', '--output', 'tsv') -AllowFailure).Output.Trim()
    if ($signedInUpn -match '@' -and $signedInUpn -notmatch '#EXT#') {
        $TenantDomain = $signedInUpn.Split('@')[-1]
    }
    else {
        throw 'Za IdentityMode Create navedite -TenantDomain, npr. contoso.onmicrosoft.com.'
    }
}

if ([string]::IsNullOrWhiteSpace($AllowedSshCidr)) {
    try {
        $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim()
        $AllowedSshCidr = "$publicIp/32"
    }
    catch {
        throw 'Nije moguce automatski utvrditi javnu IP adresu. Navedite -AllowedSshCidr, npr. 203.0.113.10/32.'
    }
}
if (-not (Test-Ipv4Cidr -Value $AllowedSshCidr)) {
    throw "AllowedSshCidr '$AllowedSshCidr' nije valjani i poravnati IPv4 CIDR zapis."
}

Write-Phase -Number 4 -Message 'Priprema korisnika, SSH kljuca i parametara'
$sshDirectory = Split-Path -Parent $SshKeyPath
New-Item -ItemType Directory -Force -Path $sshDirectory | Out-Null
if (-not (Test-Path $SshKeyPath) -or -not (Test-Path "$SshKeyPath.pub")) {
    & ssh-keygen -t ed25519 -f $SshKeyPath -N '' -C 'techsprint-azure'
    if ($LASTEXITCODE -ne 0) {
        throw 'ssh-keygen nije uspio kreirati projektni SSH kljuc.'
    }
}
$sshPublicKey = (Get-Content -Raw "$SshKeyPath.pub").Trim()

Write-Host 'Kreiranje ili razrjesavanje Entra korisnika...'

$initialPasswords = @()
$identityObjects = @()
foreach ($row in $preparedRows) {
    $upn = $row.Upn
    $password = $null
    if ($IdentityMode -eq 'Create') {
        if ([string]::IsNullOrWhiteSpace($upn)) {
            $upn = "$($row.Slug)@$TenantDomain"
        }
        $password = New-LabPassword
    }
    elseif ([string]::IsNullOrWhiteSpace($upn)) {
        throw "Korisnik '$($row.DisplayName)' nema upn stupac, a IdentityMode je Existing."
    }

    $user = Get-OrCreateUser -DisplayName $row.DisplayName -UserPrincipalName $upn -IdentityMode $IdentityMode -Password $password -ExistingObjectId $row.ObjectIdInput
    if ($IdentityMode -eq 'Create' -and $password -and $user._techsprintCreated) {
        $initialPasswords += [PSCustomObject]@{
            displayName       = $row.DisplayName
            userPrincipalName = $upn
            initialPassword   = $password
        }
    }

    $identityObjects += [PSCustomObject]@{
        FirstName   = $row.FirstName
        LastName    = $row.LastName
        DisplayName = $row.DisplayName
        Role        = $row.Role
        Slug        = $row.Slug
        Upn         = $upn
        ObjectId    = [string]$user.id
    }
}

if ($initialPasswords.Count -gt 0) {
    $initialPasswords | Export-Csv -Path $InitialPasswordPath -NoTypeInformation -Encoding UTF8
}

$leadIdentity = $identityObjects | Where-Object Role -eq 'devops_lead' | Select-Object -First 1
$developerIdentities = @($identityObjects | Where-Object Role -eq 'developer')

$developers = @()
for ($index = 0; $index -lt $developerIdentities.Count; $index++) {
    $identity = $developerIdentities[$index]
    $secondOctet = 20 + $index
    $developers += [ordered]@{
        firstName             = $identity.FirstName
        lastName              = $identity.LastName
        displayName           = $identity.DisplayName
        upn                   = $identity.Upn
        objectId              = $identity.ObjectId
        role                  = 'developer'
        slug                  = $identity.Slug
        environmentCode       = 'dev{0:D2}' -f ($index + 1)
        location              = $DeveloperLocations[$index].ToLowerInvariant()
        addressSpace          = "10.$secondOctet.0.0/16"
        appSubnetCidr         = "10.$secondOctet.1.0/24"
        dbSubnetCidr          = "10.$secondOctet.2.0/24"
        lbPrivateIp           = "10.$secondOctet.1.10"
        appPrivateIps         = @("10.$secondOctet.1.11", "10.$secondOctet.1.12")
        dbPrivateIp           = "10.$secondOctet.2.10"
        localPort             = 8080 + $index
        moodleHostname        = "moodle-$($identity.Slug).localhost"
    }
}

if (Test-Path $StatePath) {
    $state = Get-Content -Raw $StatePath | ConvertFrom-Json -Depth 20
    if ($state.PSObject.Properties.Name -contains 'subscription' -and [string]$state.subscription -ne $SubscriptionId) {
        throw "Postojeci deployment state pripada drugoj pretplati ($($state.subscription)). Nemojte ga koristiti s pretplatom $SubscriptionId."
    }
    $uniqueSuffix = [string]$state.uniqueSuffix
    if ($uniqueSuffix -notmatch '^[a-z0-9]{4,6}$') {
        throw "Postojeci deployment state sadrzava nevaljani uniqueSuffix '$uniqueSuffix'."
    }
}
else {
    $alphabet = 'abcdefghijkmnopqrstuvwxyz23456789'
    $uniqueSuffix = -join (1..5 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    [ordered]@{
        uniqueSuffix = $uniqueSuffix
        createdUtc   = [DateTime]::UtcNow.ToString('o')
        subscription = $SubscriptionId
        location     = $Location
    } | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
}

if (Test-Path $SecretPath) {
    $secretDocument = Get-Content -Raw $SecretPath | ConvertFrom-Json -AsHashtable -Depth 30
    $environmentSecrets = $secretDocument.environmentSecrets
}
else {
    $environmentSecrets = [ordered]@{}
    foreach ($developer in $developers) {
        $environmentSecrets[$developer.slug] = [ordered]@{
            dbPassword          = New-LabPassword
            moodleAdminPassword = New-LabPassword
        }
    }
    [ordered]@{
        generatedUtc       = [DateTime]::UtcNow.ToString('o')
        environmentSecrets = $environmentSecrets
    } | ConvertTo-Json -Depth 20 | Set-Content -Path $SecretPath -Encoding UTF8
}

foreach ($developer in $developers) {
    if (-not $environmentSecrets.Contains($developer.slug)) {
        $environmentSecrets[$developer.slug] = [ordered]@{
            dbPassword          = New-LabPassword
            moodleAdminPassword = New-LabPassword
        }
    }
}
$secretDocument = [ordered]@{
    generatedUtc       = [DateTime]::UtcNow.ToString('o')
    environmentSecrets = $environmentSecrets
}
$secretDocument | ConvertTo-Json -Depth 20 | Set-Content -Path $SecretPath -Encoding UTF8

$parameterDocument = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        location = @{ value = $Location }
        namePrefix = @{ value = 'techsprint' }
        uniqueSuffix = @{ value = $uniqueSuffix }
        adminUsername = @{ value = 'azureadmin' }
        sshPublicKey = @{ value = $sshPublicKey }
        deploymentRunId = @{ value = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') }
        allowedSshCidr = @{ value = $AllowedSshCidr }
        lead = @{
            value = [ordered]@{
                firstName     = $leadIdentity.FirstName
                lastName      = $leadIdentity.LastName
                displayName   = $leadIdentity.DisplayName
                upn           = $leadIdentity.Upn
                objectId      = $leadIdentity.ObjectId
                role          = 'devops_lead'
                slug          = $leadIdentity.Slug
            }
        }
        developers = @{ value = $developers }
        environmentSecrets = @{ value = $environmentSecrets }
        tags = @{
            value = [ordered]@{
                project     = 'techsprint'
                environment = 'testing'
            }
        }
    }
}
$parameterDocument | ConvertTo-Json -Depth 100 | Set-Content -Path $ParameterPath -Encoding UTF8

Write-Phase -Number 5 -Message 'Provjera regionalnih kvota i dostupnosti VM velicina'
$quotaErrors = @()
$expectedVms = @(
    [PSCustomObject]@{ Name = 'vm-techsprint-tst-jump'; Location = $Location.ToLowerInvariant(); Family = 'BSeries'; Cores = 1 }
    [PSCustomObject]@{ Name = 'vm-techsprint-tst-lead'; Location = $Location.ToLowerInvariant(); Family = 'BSeries'; Cores = 1 }
)
foreach ($developer in $developers) {
    $expectedVms += [PSCustomObject]@{ Name = "vm-techsprint-tst-$($developer.slug)-db"; Location = $developer.location; Family = 'Av2'; Cores = 1 }
    $expectedVms += [PSCustomObject]@{ Name = "vm-techsprint-tst-$($developer.slug)-app1"; Location = $developer.location; Family = 'BSeries'; Cores = 2 }
    $expectedVms += [PSCustomObject]@{ Name = "vm-techsprint-tst-$($developer.slug)-app2"; Location = $developer.location; Family = 'BSeries'; Cores = 2 }
}

$existingVms = @(Get-AzJson -Arguments @('vm', 'list'))
$missingVms = @($expectedVms | Where-Object {
    $expectedVm = $_
    -not ($existingVms | Where-Object {
        $_.name -eq $expectedVm.Name -and $_.location -eq $expectedVm.Location
    } | Select-Object -First 1)
})
$deploymentRegions = @($expectedVms | ForEach-Object Location | Select-Object -Unique)

foreach ($region in $deploymentRegions) {
    $missingInRegion = @($missingVms | Where-Object Location -eq $region)
    $requiredTotal = 0
    $requiredBSeries = 0
    $requiredAv2 = 0
    foreach ($missingVm in $missingInRegion) {
        $requiredTotal += [int]$missingVm.Cores
        if ($missingVm.Family -eq 'BSeries') {
            $requiredBSeries += [int]$missingVm.Cores
        }
        elseif ($missingVm.Family -eq 'Av2') {
            $requiredAv2 += [int]$missingVm.Cores
        }
    }

    $usage = Get-AzJson -Arguments @('vm', 'list-usage', '--location', $region)
    $regionalCpu = $usage | Where-Object { $_.name.value -eq 'cores' } | Select-Object -First 1
    $bSeriesCpu = $usage | Where-Object {
        $_.name.value -match '^standardBS.*Family$' -or $_.name.localizedValue -like '*BS Family*'
    } | Select-Object -First 1
    $av2Cpu = $usage | Where-Object {
        $_.name.value -eq 'standardAv2Family' -or $_.name.localizedValue -like '*Av2 Family*'
    } | Select-Object -First 1

    if ($null -eq $regionalCpu) {
        $quotaErrors += "$region nije vratio ukupnu regionalnu vCPU kvotu."
        continue
    }
    if ($requiredBSeries -gt 0 -and $null -eq $bSeriesCpu) {
        $quotaErrors += "$region nije vratio B-series family kvotu."
        continue
    }

    $availableTotal = [int]$regionalCpu.limit - [int]$regionalCpu.currentValue
    $availableBSeries = if ($bSeriesCpu) { [int]$bSeriesCpu.limit - [int]$bSeriesCpu.currentValue } else { 0 }
    $availableAv2 = if ($requiredAv2 -gt 0 -and $av2Cpu) {
        [int]$av2Cpu.limit - [int]$av2Cpu.currentValue
    }
    else {
        0
    }

    Write-Host "$region -> dodatno potrebno/dostupno: total $requiredTotal/$availableTotal; B-series $requiredBSeries/$availableBSeries; Av2 $requiredAv2/$availableAv2"
    if ($availableTotal -lt $requiredTotal) {
        $quotaErrors += "$region nema dovoljno ukupnih regionalnih vCPU-a ($availableTotal < $requiredTotal)."
    }
    if ($availableBSeries -lt $requiredBSeries) {
        $quotaErrors += "$region nema dovoljno B-series vCPU-a ($availableBSeries < $requiredBSeries)."
    }
    if ($requiredAv2 -gt 0 -and ($null -eq $av2Cpu -or $availableAv2 -lt $requiredAv2)) {
        $quotaErrors += "$region nema dovoljno Av2 vCPU-a ($availableAv2 < $requiredAv2)."
    }
}

if ($quotaErrors.Count -gt 0) {
    throw "Deployment je zaustavljen prije stvaranja resursa zbog kvote:`n- $($quotaErrors -join "`n- ")"
}

$requiredSkus = @(
    [PSCustomObject]@{ Location = $Location.ToLowerInvariant(); Size = 'Standard_B1s'; HyperVGeneration = 'V2' }
)
foreach ($developer in $developers) {
    $requiredSkus += [PSCustomObject]@{ Location = $developer.location; Size = 'Standard_B2s'; HyperVGeneration = 'V2' }
    $requiredSkus += [PSCustomObject]@{ Location = $developer.location; Size = 'Standard_A1_v2'; HyperVGeneration = 'V1' }
}

foreach ($skuRequirement in ($requiredSkus | Sort-Object Location, Size, HyperVGeneration -Unique)) {
    $skus = @(Get-AzJson -Arguments @(
        'vm', 'list-skus',
        '--location', $skuRequirement.Location,
        '--size', $skuRequirement.Size,
        '--all'
    ))
    $matchingSku = $skus | Where-Object name -eq $skuRequirement.Size | Select-Object -First 1
    if ($null -eq $matchingSku) {
        throw "VM SKU $($skuRequirement.Size) nije dostupan za pretplatu u regiji $($skuRequirement.Location)."
    }
    $locationRestriction = @($matchingSku.restrictions | Where-Object type -eq 'Location')
    if ($locationRestriction.Count -gt 0) {
        throw "VM SKU $($skuRequirement.Size) ima location restriction za pretplatu u regiji $($skuRequirement.Location)."
    }
    $zoneRestrictions = @($matchingSku.restrictions | Where-Object type -eq 'Zone')
    if ($zoneRestrictions.Count -gt 0) {
        Write-Host "SKU $($skuRequirement.Size) u $($skuRequirement.Location) ima ogranicene zone, ali je regionalni deployment dopusten."
    }

    $skuCapabilities = if ($matchingSku.PSObject.Properties.Name -contains 'capabilities') {
        @($matchingSku.capabilities)
    }
    else {
        @()
    }
    $hyperVCapability = $skuCapabilities | Where-Object name -eq 'HyperVGenerations' | Select-Object -First 1
    if ($null -ne $hyperVCapability) {
        $supportedGenerations = @(([string]$hyperVCapability.value).Split(',') | ForEach-Object { $_.Trim() })
        if ($skuRequirement.HyperVGeneration -notin $supportedGenerations) {
            throw "VM SKU $($skuRequirement.Size) u regiji $($skuRequirement.Location) ne podrzava trazeni Hyper-V $($skuRequirement.HyperVGeneration). Podrzano: $($supportedGenerations -join ', ')."
        }
    }
}

Write-Phase -Number 6 -Message 'Lokalna Bicep kompilacija'
$bicepCheck = Invoke-Az -Arguments @('bicep', 'version') -AllowFailure
if ($bicepCheck.ExitCode -ne 0) {
    throw "Bicep CLI nije ispravno instaliran. Pokrenite 'az bicep uninstall', zatim 'az bicep install', pa ponovno otvorite PowerShell."
}
Write-Host $bicepCheck.Output
Invoke-Az -Arguments @('bicep', 'build', '--file', $TemplatePath, '--outfile', $CompiledTemplatePath) | Out-Null

Write-Phase -Number 7 -Message 'Azure ARM validacija bez stvaranja resursa'
Invoke-Az -Arguments @(
    'deployment', 'sub', 'validate',
    '--name', 'techsprint-validation',
    '--location', $Location,
    '--template-file', $TemplatePath,
    '--parameters', "@$ParameterPath",
    '--output', 'none'
) | Out-Null

if (-not $SkipWhatIf) {
    Write-Phase -Number 8 -Message 'Sažeti Azure What-If pregled promjena'
    # Azure What-If ponekad u JSON ukljuci NaN, sto PowerShell ConvertFrom-Json
    # odbija. Zato od Azure CLI-a trazimo samo changeType vrijednosti kao TSV.
    $whatIfResponse = Invoke-Az -Arguments @(
        'deployment', 'sub', 'what-if',
        '--name', 'techsprint-whatif',
        '--location', $Location,
        '--template-file', $TemplatePath,
        '--parameters', "@$ParameterPath",
        '--result-format', 'ResourceIdOnly',
        '--query', 'properties.changes[].changeType',
        '--output', 'tsv'
    )
    $whatIfChangeTypes = @($whatIfResponse.Output -split "`r?`n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($whatIfChangeTypes.Count -eq 0) {
        Write-Host 'What-If: nema promjena.'
    }
    else {
        $changeSummary = @($whatIfChangeTypes | Group-Object | Sort-Object Name | ForEach-Object {
            "$($_.Name) $($_.Count)"
        }) -join '; '
        Write-Host "What-If: $changeSummary"
    }
}
else {
    Write-Phase -Number 8 -Message 'Azure What-If je preskocen parametrom -SkipWhatIf'
}

if ($ValidationOnly) {
    Write-Host ''
    Write-Host 'VALIDACIJA JE USPJELA. Nijedan Azure resurs nije stvoren.' -ForegroundColor Green
    Write-Host 'Za pravi deployment ponovite istu naredbu bez parametra -ValidationOnly.'
    return
}

$deploymentName = "techsprint-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
Write-Phase -Number 9 -Message "Pokretanje i pracenje Bicep deploymenta '$deploymentName'"
Invoke-Az -Arguments @(
    'deployment', 'sub', 'create',
    '--name', $deploymentName,
    '--location', $Location,
    '--template-file', $TemplatePath,
    '--parameters', "@$ParameterPath",
    '--no-wait',
    '--output', 'none'
) | Out-Null
$deployment = Wait-SubscriptionDeployment -DeploymentName $deploymentName

$baseSummary = $deployment.properties.outputs.deploymentSummary.value
$summary = [ordered]@{
    jumpPublicIp  = $baseSummary.jumpPublicIp
    jumpPrivateIp = $baseSummary.jumpPrivateIp
    leadPrivateIp = $baseSummary.leadPrivateIp
    leadObjectId  = $baseSummary.leadObjectId
    sshToJump     = $baseSummary.sshToJump
    sshToLead     = $baseSummary.sshToLead
    environments  = @($deployment.properties.outputs.environments.value)
}

Write-Phase -Number 10 -Message 'Pracenje Moodle bootstrapa po VM-u'
Wait-AppBootstrap -Environments $summary.environments -TimeoutMinutes $BootstrapTimeoutMinutes

$summaryPath = Join-Path $OutputDirectory 'deployment-summary.json'
$summary | ConvertTo-Json -Depth 30 | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host ''
Write-Host 'DEPLOYMENT JE ZAVRSEN.' -ForegroundColor Green
Write-Host "Jump Host public IP: $($summary.jumpPublicIp)"
Write-Host "SSH Jump: $($summary.sshToJump)"
Write-Host "SSH Lead: $($summary.sshToLead)"
foreach ($environment in $summary.environments) {
    Write-Host "Moodle $($environment.developer): $($environment.moodleTunnel) -> $($environment.localMoodleUrl)"
}
Write-Host "Saetak: $summaryPath"
Write-Host "Tajne za laboratorij: $SecretPath"
if (Test-Path $InitialPasswordPath) {
    Write-Host "Pocetne Entra lozinke: $InitialPasswordPath"
}
Write-Warning 'Azure for Students ima 100 USD kredita za 12 mjeseci. Nakon snimanja dokaza zaustavite/dealocirajte VM-ove ili pokrenite destroy.ps1.'
