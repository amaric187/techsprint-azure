[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw 'Nije moguce postaviti Azure subscription context.'
}

$groupsJson = az group list --tag project=techsprint --only-show-errors --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Nije moguce procitati Resource Grupe.'
}
$groups = @($groupsJson | ConvertFrom-Json -Depth 30) | Where-Object {
    $hasEnvironmentTag = $null -ne $_.tags -and ($_.tags.PSObject.Properties.Name -contains 'environment')
    $_.name -like 'rg-techsprint-tst-*' -and $hasEnvironmentTag -and $_.tags.environment -eq 'testing'
}

if ($groups.Count -eq 0) {
    Write-Host 'Nema TechSprint testing Resource Grupa za brisanje.'
    return
}

Write-Host 'Brisat ce se iskljucivo sljedece Resource Grupe:' -ForegroundColor Yellow
$groups.name | Sort-Object | ForEach-Object { Write-Host "  $_" }

$approved = $Force
if (-not $approved) {
    $confirmation = Read-Host "Upisite DELETE-TECHSPRINT za potvrdu"
    $approved = $confirmation -ceq 'DELETE-TECHSPRINT'
}
if (-not $approved) {
    Write-Host 'Brisanje je otkazano.'
    return
}

foreach ($group in $groups) {
    if ($PSCmdlet.ShouldProcess($group.name, 'Delete Azure Resource Group')) {
        az group delete --name $group.name --yes --no-wait --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Nije uspjelo pokretanje brisanja Resource Grupe '$($group.name)'."
        }
    }
}

Write-Host 'Brisanje je pokrenuto. Resource Grupe se brisu u pozadini.' -ForegroundColor Green
Write-Host 'Pratim stanje brisanja; ovo moze potrajati nekoliko minuta.'

$pendingNames = @($groups.name)
$deadline = (Get-Date).AddMinutes(60)
while ($pendingNames.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $stillPresent = @()
    foreach ($groupName in $pendingNames) {
        $exists = az group exists --name $groupName --only-show-errors --output tsv
        if ($LASTEXITCODE -ne 0) {
            throw "Nije moguce provjeriti stanje Resource Grupe '$groupName'."
        }
        if ($exists.Trim().ToLowerInvariant() -eq 'true') {
            $stillPresent += $groupName
        }
    }
    if ($stillPresent.Count -ne $pendingNames.Count) {
        $deletedCount = $groups.Count - $stillPresent.Count
        Write-Host "  Obrisano $deletedCount/$($groups.Count) Resource Grupa."
    }
    $pendingNames = @($stillPresent)
}

if ($pendingNames.Count -gt 0) {
    Write-Warning "Brisanje jos traje za: $($pendingNames -join ', '). Provjerite ih kasnije naredbom 'az group list --output table'."
    return
}

Write-Host 'Sve TechSprint Resource Grupe su obrisane.' -ForegroundColor Green
$roleId = az role definition list --name 'TechSprint VM Power Operator' --query '[0].name' --output tsv --only-show-errors
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($roleId)) {
    az role definition delete --name 'TechSprint VM Power Operator' --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Resource Grupe su obrisane, ali custom rolu nije moguce odmah ukloniti. Pricekajte nekoliko minuta pa pokrenite: az role definition delete --name "TechSprint VM Power Operator"'
    }
    else {
        Write-Host 'Custom rola TechSprint VM Power Operator je obrisana.' -ForegroundColor Green
    }
}

Write-Host 'Azure TechSprint okolina je uklonjena.' -ForegroundColor Green
