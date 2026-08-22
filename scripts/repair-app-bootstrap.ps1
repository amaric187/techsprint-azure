[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [ValidateRange(15, 120)]
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Get-BootstrapStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$VmName
    )

    $statusCommand = 'state=RUNNING; if [ -f /var/lib/techsprint/app-ready ] && grep -qx 3 /var/lib/techsprint/app-bootstrap-version 2>/dev/null; then state=READY; elif [ -f /var/lib/techsprint/app-error ]; then state=FAILED; fi; stage=$(cat /var/lib/techsprint/app-stage 2>/dev/null || echo "VM se pokrece"); error=$(tail -n 1 /var/lib/techsprint/app-error 2>/dev/null || true); printf "TSSTATE=%s;TSSTAGE=%s;TSERROR=%s;TSEND=1" "$state" "$stage" "$error"'
    $statusBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($statusCommand))
    $remoteStatusCommand = "printf '%s' '$statusBase64' | base64 -d | bash"
    $response = Invoke-Az -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroup,
        '--name', $VmName,
        '--command-id', 'RunShellScript',
        '--query', 'value[0].message',
        '--output', 'tsv',
        '--scripts', $remoteStatusCommand
    ) -AllowFailure

    if ($response.ExitCode -ne 0) {
        return [PSCustomObject]@{ State = 'WAITING'; Stage = 'cekam Azure VM Agent'; Error = '' }
    }
    $stateMatch = [regex]::Match($response.Output, 'TSSTATE=([^;]+);')
    $stageMatch = [regex]::Match($response.Output, 'TSSTAGE=(.*?);TSERROR=', [Text.RegularExpressions.RegexOptions]::Singleline)
    $errorMatch = [regex]::Match($response.Output, 'TSERROR=(.*?);TSEND=1', [Text.RegularExpressions.RegexOptions]::Singleline)
    return [PSCustomObject]@{
        State = if ($stateMatch.Success) { $stateMatch.Groups[1].Value.Trim() } else { 'RUNNING' }
        Stage = if ($stageMatch.Success) { $stageMatch.Groups[1].Value.Trim() } else { 'VM se pokrece' }
        Error = if ($errorMatch.Success) { $errorMatch.Groups[1].Value.Trim() } else { '' }
    }
}

Invoke-Az -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repairPath = Join-Path $projectRoot 'cloud-init\app-repair.sh'
$repairScript = Get-Content -Raw -Path $repairPath
$repairBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($repairScript))

$vmResponse = Invoke-Az -Arguments @(
    'resource', 'list',
    '--resource-type', 'Microsoft.Compute/virtualMachines',
    '--output', 'json'
)
$appVms = @($vmResponse.Output | ConvertFrom-Json -Depth 30) | Where-Object {
    $hasProjectTag = $null -ne $_.tags -and ($_.tags.PSObject.Properties.Name -contains 'project')
    $hasEnvironmentTag = $null -ne $_.tags -and ($_.tags.PSObject.Properties.Name -contains 'environment')
    $isTechSprint = $hasProjectTag -and $_.tags.project -eq 'techsprint'
    $isTesting = $hasEnvironmentTag -and $_.tags.environment -eq 'testing'
    $isTechSprint -and $isTesting -and $_.name -match '-app[12]$'
} | Sort-Object resourceGroup, name

if ($appVms.Count -eq 0) {
    throw 'Nisu pronadeni TechSprint aplikacijski VM-ovi.'
}

Write-Host "Pronadeno aplikacijskih VM-ova: $($appVms.Count)" -ForegroundColor Cyan
foreach ($vm in $appVms) {
    Write-Host "  Pokrecem popravak: $($vm.name)"
    $command = "printf '%s' '$repairBase64' | base64 -d | bash"
    $result = Invoke-Az -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', [string]$vm.resourceGroup,
        '--name', [string]$vm.name,
        '--command-id', 'RunShellScript',
        '--query', 'value[0].message',
        '--output', 'tsv',
        '--scripts', $command
    )
    if ($result.Output -notmatch 'REPAIR_STARTED|ALREADY_READY') {
        throw "VM '$($vm.name)' nije potvrdio pokretanje popravka.`n$($result.Output)"
    }
}

Write-Host ''
Write-Host 'Popravak je pokrenut. Pratim Moodle faze...' -ForegroundColor Cyan
$started = Get-Date
$deadline = $started.AddMinutes($TimeoutMinutes)
$lastStatus = @{}

while ((Get-Date) -lt $deadline) {
    $readyCount = 0
    foreach ($vm in $appVms) {
        $status = Get-BootstrapStatus -ResourceGroup $vm.resourceGroup -VmName $vm.name
        $display = "$($status.State): $($status.Stage)"
        if (-not $lastStatus.ContainsKey($vm.name) -or $lastStatus[$vm.name] -ne $display) {
            $elapsed = (Get-Date) - $started
            $elapsedText = '{0:00}:{1:00}:{2:00}' -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
            Write-Host "  [Moodle $elapsedText] $($vm.name) -> $display"
            $lastStatus[$vm.name] = $display
        }
        if ($status.State -eq 'READY') {
            $readyCount++
        }
        elseif ($status.State -eq 'FAILED') {
            throw "Bootstrap VM-a '$($vm.name)' nije uspio u fazi '$($status.Stage)'. $($status.Error)"
        }
    }
    if ($readyCount -eq $appVms.Count) {
        Write-Host "Sva $readyCount Moodle aplikacijska VM-a su spremna." -ForegroundColor Green
        return
    }
    Start-Sleep -Seconds 30
}

throw "Moodle bootstrap nije zavrsio unutar $TimeoutMinutes minuta."
