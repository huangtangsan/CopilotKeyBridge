[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$DisplayName = 'CopilotKeyBridge integration test',
    [switch]$UninstallAfter,
    [switch]$AssumeInstalled
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$targetPath = (Resolve-Path -LiteralPath $Target).ProviderPath
$targetName = [IO.Path]::GetFileNameWithoutExtension($targetPath)
$completed = $false

try {
    $existingTargetProcesses = @(Get-Process -Name $targetName -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -eq $targetPath } catch { $false }
        })
    if ($existingTargetProcesses.Count -gt 0) {
        throw 'The target must not be running before the integration test starts.'
    }

    if (-not $AssumeInstalled) {
        & (Join-Path $root 'install.ps1') -Target $targetPath -DisplayName $DisplayName
    }

    $package = Get-AppxPackage -Name CopilotKeyBridge -ErrorAction Stop
    $aumid = "$($package.PackageFamilyName)!Bridge"
    $startEntry = Get-StartApps | Where-Object AppID -eq $aumid
    if ($null -eq $startEntry) {
        throw "Installed AUMID was not visible in Get-StartApps: $aumid"
    }

    Write-Host "Launching AUMID: $aumid"
    $beforeIds = @($existingTargetProcesses | ForEach-Object Id)
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "shell:AppsFolder\$aumid"
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $targetProcesses = @(Get-Process -Name $targetName -ErrorAction SilentlyContinue |
            Where-Object {
                try { $_.Path -eq $targetPath } catch { $false }
            })
        $targetProcess = $targetProcesses |
            Where-Object Id -notin $beforeIds |
            Where-Object MainWindowHandle -ne 0 |
            Select-Object -First 1
    } while ($null -eq $targetProcess -and (Get-Date) -lt $deadline)
    if ($null -eq $targetProcess) {
        throw 'AUMID activation did not cold-start a new target process with a top-level window.'
    }

    $launcherCount = @(Get-Process -Name CopilotKeyBridge -ErrorAction SilentlyContinue).Count
    if ($launcherCount -ne 0) {
        throw "The bridge should not remain resident. Found $launcherCount process(es)."
    }

    $privateKeys = @(Get-ChildItem Cert:\CurrentUser\My |
        Where-Object Subject -eq 'CN=CopilotKeyBridge Local Package')
    if ($privateKeys.Count -ne 0) {
        throw "The ephemeral signing private key was not removed. Found $($privateKeys.Count) certificate(s)."
    }

    Write-Host 'Integration cold activation passed.' -ForegroundColor Green
    $completed = $true
}
finally {
    if ($UninstallAfter -and $completed -and $null -ne (Get-AppxPackage -Name CopilotKeyBridge -ErrorAction SilentlyContinue)) {
        & (Join-Path $root 'uninstall.ps1') -Force
        if ($null -ne (Get-AppxPackage -Name CopilotKeyBridge -ErrorAction SilentlyContinue)) {
            throw 'Package remained after integration-test uninstall.'
        }
    }
}
