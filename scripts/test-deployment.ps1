[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [switch]$SkipGuestTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SummaryPath = Join-Path $ProjectRoot 'output\deployment-summary.json'
$OutputDirectory = Join-Path $ProjectRoot 'output'

if (-not (Test-Path $SummaryPath)) {
    throw "Nedostaje $SummaryPath. Najprije pokrenite deploy.ps1."
}

function Invoke-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI naredba nije uspjela: az $($Arguments -join ' ')`n$($result -join [Environment]::NewLine)"
    }
    return ($result -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Evidence
    )
    $script:Checks += [PSCustomObject]@{
        check    = $Name
        passed   = $Passed
        evidence = $Evidence
    }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host "[$(if ($Passed) { 'PASS' } else { 'FAIL' })] $Name - $Evidence" -ForegroundColor $color
}

function Invoke-RunCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$Script
    )
    $result = Invoke-AzJson -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroup,
        '--name', $VmName,
        '--command-id', 'RunShellScript',
        '--scripts', $Script
    )
    return ($result.value.message -join "`n")
}

az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw 'Nije moguce postaviti Azure subscription context.'
}

$summary = Get-Content -Raw $SummaryPath | ConvertFrom-Json -Depth 30
$script:Checks = @()

$resourceGroups = @(Invoke-AzJson -Arguments @('group', 'list', '--tag', 'project=techsprint')) |
    Where-Object { $_.tags.environment -eq 'testing' -and $_.name -like 'rg-techsprint-tst-*' }
Add-Check -Name 'Logicka hijerarhija Resource Grupa' -Passed ($resourceGroups.Count -eq ($summary.environments.Count + 1)) -Evidence "$($resourceGroups.Count) projektnih Resource Grupa"

$allResources = @()
foreach ($resourceGroup in $resourceGroups) {
    $allResources += @(Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $resourceGroup.name))
}
$tagExceptions = @(
    'Microsoft.Authorization/roleAssignments',
    'Microsoft.Network/virtualNetworks/subnets',
    'Microsoft.Network/virtualNetworks/virtualNetworkPeerings',
    'Microsoft.Storage/storageAccounts/blobServices',
    'Microsoft.Storage/storageAccounts/blobServices/containers',
    'Microsoft.Storage/storageAccounts/fileServices',
    'Microsoft.Storage/storageAccounts/fileServices/shares'
)
$untagged = @($allResources | Where-Object {
    $_.type -notin $tagExceptions -and
    ($null -eq $_.tags -or $_.tags.project -ne 'techsprint' -or $_.tags.environment -ne 'testing')
})
Add-Check -Name 'Obavezni tagovi' -Passed ($untagged.Count -eq 0) -Evidence "Netagirani taggable resursi: $($untagged.Count)"

$publicIps = @()
foreach ($resourceGroup in $resourceGroups) {
    $publicIps += @(Invoke-AzJson -Arguments @('network', 'public-ip', 'list', '--resource-group', $resourceGroup.name))
}
Add-Check -Name 'Samo Jump Host ima javni IP' -Passed ($publicIps.Count -eq 1 -and $publicIps[0].name -like '*jump*') -Evidence "Javne IP adrese: $($publicIps.name -join ', ')"

$virtualMachines = @()
foreach ($resourceGroup in $resourceGroups) {
    $virtualMachines += @(Invoke-AzJson -Arguments @('vm', 'list', '--resource-group', $resourceGroup.name))
}
$appVms = @($virtualMachines | Where-Object name -Like '*-app?')
$dbVms = @($virtualMachines | Where-Object name -Like '*-db')
$badAppSizes = @($appVms | Where-Object { $_.hardwareProfile.vmSize -ne 'Standard_B2s' })
$badAppDisks = @($appVms | Where-Object { $_.storageProfile.dataDisks.Count -ne 1 })
$badDbSizes = @($dbVms | Where-Object { $_.hardwareProfile.vmSize -ne 'Standard_A1_v2' })
Add-Check -Name 'App VM specifikacije' -Passed ($appVms.Count -eq (2 * $summary.environments.Count) -and $badAppSizes.Count -eq 0) -Evidence "$($appVms.Count) app VM-ova, svi Standard_B2s: $($badAppSizes.Count -eq 0)"
Add-Check -Name 'OS i data disk na svakom app VM-u' -Passed ($badAppDisks.Count -eq 0) -Evidence "App VM-ovi bez jednog data diska: $($badAppDisks.Count)"
Add-Check -Name 'DB VM koristi odvojenu Av2 kvotu' -Passed ($dbVms.Count -eq $summary.environments.Count -and $badDbSizes.Count -eq 0) -Evidence "$($dbVms.Count) DB VM-ova, svi Standard_A1_v2: $($badDbSizes.Count -eq 0)"

foreach ($environment in $summary.environments) {
    $environmentVms = @($virtualMachines | Where-Object resourceGroup -eq $environment.resourceGroup)
    $wrongRegionVms = @($environmentVms | Where-Object location -ne $environment.location)
    Add-Check -Name "Developer regija $($environment.slug)" -Passed ($environmentVms.Count -eq 3 -and $wrongRegionVms.Count -eq 0) -Evidence "$($environment.resourceGroup) -> $($environment.location); VM-ovi u pogresnoj regiji: $($wrongRegionVms.Count)"
}

$roleDefinitions = @(Invoke-AzJson -Arguments @('role', 'definition', 'list', '--name', 'TechSprint VM Power Operator'))
$requiredPowerActions = @(
    'Microsoft.Compute/virtualMachines/read',
    'Microsoft.Compute/virtualMachines/start/action',
    'Microsoft.Compute/virtualMachines/deallocate/action',
    'Microsoft.Compute/virtualMachines/powerOff/action',
    'Microsoft.Compute/virtualMachines/restart/action'
)
$actualPowerActions = if ($roleDefinitions.Count -eq 1) { @($roleDefinitions[0].permissions[0].actions) } else { @() }
$missingPowerActions = @($requiredPowerActions | Where-Object { $_ -notin $actualPowerActions })
Add-Check -Name 'Minimalna custom VM power rola' -Passed ($roleDefinitions.Count -eq 1 -and $missingPowerActions.Count -eq 0 -and $roleDefinitions[0].permissions[0].dataActions.Count -eq 0) -Evidence "Definicija pronadjena: $($roleDefinitions.Count -eq 1); nedostajuce power akcije: $($missingPowerActions.Count)"

foreach ($environment in $summary.environments) {
    $resourceGroupScope = "/subscriptions/$SubscriptionId/resourceGroups/$($environment.resourceGroup)"
    $assignments = @(Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--scope', $resourceGroupScope))
    $developerAssignment = @($assignments | Where-Object {
        $_.principalId -eq $environment.principalObjectId -and
        $_.roleDefinitionName -eq 'TechSprint VM Power Operator' -and
        $_.scope -eq $resourceGroupScope
    })
    $leadAssignment = @($assignments | Where-Object {
        $_.principalId -eq $summary.leadObjectId -and
        $_.roleDefinitionName -eq 'TechSprint VM Power Operator' -and
        $_.scope -eq $resourceGroupScope
    })
    Add-Check -Name "Developer RBAC scope $($environment.slug)" -Passed ($developerAssignment.Count -eq 1) -Evidence "Developer korisnik ima power rolu na $($environment.resourceGroup): $($developerAssignment.Count -eq 1)"
    Add-Check -Name "Lead RBAC scope $($environment.slug)" -Passed ($leadAssignment.Count -eq 1) -Evidence "Lead korisnik ima power rolu na $($environment.resourceGroup): $($leadAssignment.Count -eq 1)"
}

$loadBalancers = @()
$storageAccounts = @()
foreach ($environment in $summary.environments) {
    $loadBalancers += @(Invoke-AzJson -Arguments @('network', 'lb', 'list', '--resource-group', $environment.resourceGroup))
    $storageAccounts += @(Invoke-AzJson -Arguments @('storage', 'account', 'list', '--resource-group', $environment.resourceGroup))
}
$publicFrontends = @($loadBalancers.frontendIpConfigurations | Where-Object {
    $_.PSObject.Properties.Name -contains 'publicIPAddress' -and
    $null -ne $_.publicIPAddress
})
Add-Check -Name 'Interni Standard Load Balancer po developeru' -Passed ($loadBalancers.Count -eq $summary.environments.Count -and $publicFrontends.Count -eq 0) -Evidence "$($loadBalancers.Count) internih LB-ova"

$badStorage = @($storageAccounts | Where-Object {
    $_.allowSharedKeyAccess -ne $false -or $_.networkRuleSet.defaultAction -ne 'Deny'
})
$fileStorage = @($storageAccounts | Where-Object {
    $_.PSObject.Properties.Name -contains 'azureFilesIdentityBasedAuthentication' -and
    $null -ne $_.azureFilesIdentityBasedAuthentication -and
    $_.azureFilesIdentityBasedAuthentication.PSObject.Properties.Name -contains 'smbOAuthSettings' -and
    $null -ne $_.azureFilesIdentityBasedAuthentication.smbOAuthSettings -and
    $_.azureFilesIdentityBasedAuthentication.smbOAuthSettings.PSObject.Properties.Name -contains 'isSmbOAuthEnabled' -and
    $_.azureFilesIdentityBasedAuthentication.smbOAuthSettings.isSmbOAuthEnabled -eq $true
})
Add-Check -Name 'Storage least privilege' -Passed ($storageAccounts.Count -eq (2 * $summary.environments.Count) -and $badStorage.Count -eq 0) -Evidence "$($storageAccounts.Count) accounta; Shared Key iskljucen i firewall Deny: $($badStorage.Count -eq 0)"
Add-Check -Name 'Azure Files SMB OAuth' -Passed ($fileStorage.Count -eq $summary.environments.Count) -Evidence "$($fileStorage.Count) file storage accounta s Managed Identity SMB OAuthom"

if (-not $SkipGuestTests) {
    foreach ($environment in $summary.environments) {
        for ($index = 0; $index -lt $environment.appPrivateIps.Count; $index++) {
            $vmName = "vm-techsprint-tst-$($environment.slug)-app$($index + 1)"
            $guestOutput = Invoke-RunCommand -ResourceGroup $environment.resourceGroup -VmName $vmName -Script 'set -e; mountpoint -q /mnt/moodleblob; mountpoint -q /mnt/moodlebackup; test $(lsblk -dn -o TYPE | grep -c disk) -ge 2; curl -fsS http://127.0.0.1/health.html; curl -fsSI https://packages.microsoft.com >/dev/null; echo TECHSPRINT_GUEST_PASS'
            Add-Check -Name "Guest mount/disk/Internet $vmName" -Passed ($guestOutput -match 'TECHSPRINT_GUEST_PASS') -Evidence (($guestOutput -replace "`r|`n", ' ') -replace '\s+', ' ')
        }
    }

    if ($summary.environments.Count -ge 2) {
        $source = $summary.environments[0]
        $targetIp = $summary.environments[1].appPrivateIps[0]
        $sourceVm = "vm-techsprint-tst-$($source.slug)-app1"
        $isolationOutput = Invoke-RunCommand -ResourceGroup $source.resourceGroup -VmName $sourceVm -Script "if timeout 5 bash -c '</dev/tcp/$targetIp/22' 2>/dev/null; then echo ISOLATION_FAIL; else echo ISOLATION_PASS; fi"
        Add-Check -Name 'Mrezna izolacija developer VNetova' -Passed ($isolationOutput -match 'ISOLATION_PASS') -Evidence "Pokusaj $sourceVm -> ${targetIp}:22 je blokiran"
    }

    $sharedGroup = ($resourceGroups | Where-Object name -Like '*-shared-*' | Select-Object -First 1).name
    $leadTargets = ($summary.environments.appPrivateIps | ForEach-Object { $_ }) -join ' '
    $leadOutput = Invoke-RunCommand -ResourceGroup $sharedGroup -VmName 'vm-techsprint-tst-lead' -Script "set -e; for ip in $leadTargets; do nc -z -w 5 `$ip 22; done; echo LEAD_ACCESS_PASS"
    Add-Check -Name 'Lead pristup svim app VM-ovima' -Passed ($leadOutput -match 'LEAD_ACCESS_PASS') -Evidence 'TCP/22 je dostupan iz Lead VM-a prema svim app VM-ovima'
}

$report = [ordered]@{
    testedUtc  = [DateTime]::UtcNow.ToString('o')
    passed     = (@($Checks | Where-Object passed).Count)
    failed     = (@($Checks | Where-Object { -not $_.passed }).Count)
    checks     = $Checks
}
$reportPath = Join-Path $OutputDirectory "test-results-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).json"
$report | ConvertTo-Json -Depth 30 | Set-Content -Path $reportPath -Encoding UTF8
Write-Host "Izvjestaj: $reportPath"

if ($report.failed -gt 0) {
    throw "Deployment nije prosao sve provjere. Broj neuspjelih provjera: $($report.failed)."
}


